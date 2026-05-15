"""数据层：PiezoLUT 插值查表 + CSVWriter 持久化。"""
from __future__ import annotations

from pathlib import Path
from typing import TYPE_CHECKING, Optional

import numpy as np
import pandas as pd
from scipy.interpolate import RegularGridInterpolator
from scipy.optimize import brentq

from config import Config
from models import ModelParams
from utils import DataStore

if TYPE_CHECKING:
    pass

_LUT_COLUMNS = [
    "temperature_C", "voltage_V", "direction", "mean_nm", "std_nm",
    "sem_nm", "ci_95_nm", "n_samples", "outliers_removed", "timestamp",
]


class PiezoLUT:
    """
    Piezo 电压-位移查找表，支持正向和反向插值查询。

    正向查询：(温度, 电压) → 位移 nm
    反向查询：(温度, 目标位移 nm) → 电压 V  （Brent 二分法）
    """

    def __init__(self, df: pd.DataFrame) -> None:
        self._df = df.copy()
        self._interpolators: dict[str, RegularGridInterpolator] = {}
        self._v_bounds: dict[str, tuple[float, float]] = {}
        self._build_interpolators()

    def _build_interpolators(self) -> None:
        for direction in ("up", "down"):
            sub = self._df[self._df["direction"] == direction]
            if sub.empty:
                continue
            temps    = sorted(sub["temperature_C"].unique())
            voltages = sorted(sub["voltage_V"].unique())
            grid = np.zeros((len(temps), len(voltages)), dtype=float)
            for ti, temp in enumerate(temps):
                for vi, volt in enumerate(voltages):
                    row = sub[
                        (sub["temperature_C"] == temp) & (sub["voltage_V"] == volt)
                    ]
                    grid[ti, vi] = float(row["mean_nm"].iloc[0]) if not row.empty else 0.0
            self._interpolators[direction] = RegularGridInterpolator(
                (np.array(temps, dtype=float), np.array(voltages, dtype=float)),
                grid, method="linear", bounds_error=False, fill_value=None,
            )
            self._v_bounds[direction] = (min(voltages), max(voltages))

    @classmethod
    def from_csv(cls, path: str) -> "PiezoLUT":
        df = pd.read_csv(path)
        required = {"temperature_C", "voltage_V", "direction", "mean_nm"}
        missing = required - set(df.columns)
        if missing:
            raise ValueError(f"CSV 缺少必要列: {missing}")
        return cls(df)

    def forward(
        self, temp_C: float, voltage_V: float, direction: str = "up"
    ) -> float:
        interp = self._interpolators.get(direction)
        if interp is None:
            raise ValueError(f'方向 "{direction}" 无数据，请检查 CSV')
        return float(interp([[float(temp_C), float(voltage_V)]])[0])

    def inverse(
        self, temp_C: float, target_nm: float, direction: str = "up"
    ) -> float:
        if direction not in self._v_bounds:
            raise ValueError(f'方向 "{direction}" 无数据')
        v_min, v_max = self._v_bounds[direction]

        def residual(v: float) -> float:
            return self.forward(temp_C, v, direction) - target_nm

        fa, fb = residual(v_min), residual(v_max)
        if fa * fb > 0:
            return v_min if abs(fa) < abs(fb) else v_max
        return float(brentq(residual, v_min, v_max, xtol=1e-6, maxiter=100))

    def temperatures(self) -> list[float]:
        return sorted(self._df["temperature_C"].unique().tolist())

    def voltage_range(self, direction: str = "up") -> tuple[float, float]:
        return self._v_bounds.get(direction, (0.0, 0.0))

    def displacement_range(self, direction: str = "up") -> tuple[float, float]:
        """返回该方向 LUT 数据的位移范围 (min_nm, max_nm)。"""
        sub = self._df[self._df["direction"] == direction]
        if sub.empty:
            return (0.0, 0.0)
        return (float(sub["mean_nm"].min()), float(sub["mean_nm"].max()))

    def available_directions(self) -> list[str]:
        """返回 LUT 中实际存在数据的方向列表。"""
        return list(self._interpolators.keys())


class CSVWriter:
    """将测量数据和统计摘要保存为 CSV 文件。"""

    def __init__(self, cfg: Config, timestamp: str) -> None:
        self._cfg = cfg
        self._ts = timestamp
        Path(cfg.output_dir).mkdir(parents=True, exist_ok=True)

    def save_partial(self, store: DataStore, temp_C: float) -> Path:
        path = Path(self._cfg.output_dir) / f"lut_partial_{int(temp_C)}C.csv"
        df = store.to_dataframe()
        if not df.empty:
            df[df["temperature_C"] == temp_C][_LUT_COLUMNS].to_csv(path, index=False)
        return path

    def save_full(self, store: DataStore) -> Path:
        path = Path(self._cfg.output_dir) / f"lut_{self._ts}.csv"
        df = store.to_dataframe()
        if not df.empty:
            df[_LUT_COLUMNS].to_csv(path, index=False)
        return path

    def save_summary(self, store: DataStore) -> Path:
        path = Path(self._cfg.output_dir) / f"summary_{self._ts}.csv"
        df = store.to_dataframe()
        rows = []

        for temp, grp in df.groupby("temperature_C"):
            up = grp[grp["direction"] == "up"].sort_values("voltage_V")
            dn = grp[grp["direction"] == "down"].sort_values("voltage_V")
            max_disp = float(grp["mean_nm"].max())
            merged = up.merge(dn, on="voltage_V", suffixes=("_up", "_dn"))
            hyst = 0.0
            if not merged.empty:
                hyst = float(
                    (merged["mean_nm_up"] - merged["mean_nm_dn"]).abs().max()
                )
            r2 = float("nan")
            sensitivity = float("nan")
            if len(up) >= 2:
                v = up["voltage_V"].values
                d = up["mean_nm"].values
                coeffs = np.polyfit(v, d, 1)
                fitted = np.polyval(coeffs, v)
                ss_res = float(np.sum((d - fitted) ** 2))
                ss_tot = float(np.sum((d - d.mean()) ** 2))
                r2 = 1.0 - ss_res / ss_tot if ss_tot > 0 else 1.0
                sensitivity = float(coeffs[0])
            rows.append({
                "temperature_C": temp,
                "max_displacement_nm": max_disp,
                "hysteresis_max_nm": hyst,
                "linearity_r2": r2,
                "sensitivity_nm_per_V": sensitivity,
            })

        pd.DataFrame(rows).to_csv(path, index=False)
        return path

    def save_model_params(self, params: list[ModelParams]) -> Path:
        path = Path(self._cfg.output_dir) / f"model_{self._ts}.csv"
        pd.DataFrame([p.__dict__ for p in params]).to_csv(path, index=False)
        return path
