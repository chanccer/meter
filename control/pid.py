"""离散时间 PI/PID 控制器，含积分抗饱和。"""
from __future__ import annotations


class PIDController:
    """
    离散时间 PI/PID。

    输入：位移误差（nm）
    输出：电压修正量（V）
    """

    def __init__(
        self,
        kp: float,
        ki: float,
        kd: float,
        integral_limit: float,
    ) -> None:
        self.kp = kp
        self.ki = ki
        self.kd = kd
        self.integral_limit = integral_limit
        self._integral = 0.0
        self._prev_error = 0.0

    def reset(self) -> None:
        self._integral = 0.0
        self._prev_error = 0.0

    def update(self, error_nm: float, dt: float) -> float:
        """
        计算本次迭代的电压修正量（V）。

        error_nm: 目标位移 - 当前位移（正值需增大位移）
        dt: 距上次调用的时间间隔（s）
        """
        # 积分项（限幅防飞车）
        self._integral += error_nm * dt
        i_contribution = max(
            -self.integral_limit,
            min(self.integral_limit, self.ki * self._integral),
        )
        if self.ki > 1e-12:
            self._integral = i_contribution / self.ki

        # 微分项（基于误差差分）
        d_contribution = (
            self.kd * (error_nm - self._prev_error) / dt if dt > 1e-6 else 0.0
        )
        self._prev_error = error_nm

        return self.kp * error_nm + i_contribution + d_contribution
