"""isolation.58 契约：参考 Battman 的机型无关亮度上限与屏幕硬件温度。

Battman（Torrekie）的做法：
  * 上限来自 CoreBrightness 的 VirtualBrightnessLimits：HardwareAccessibleMaxNits /
    UserAccessibleMaxNits / MinNitsAccessibleWithDigitalDimming，机型与 iOS 版本无关；
  * 屏幕硬件温度来自 IOMobileFramebuffer block 0（温度补偿状态），Q16.16，
    v3 取 [92]、v1 取 [84]；不支持的机型回退 IORegistry 的 APTPDCTemperature。

CPUthermal 只用这两条只读通道来做“最高亮度保护与守护”，绝不写温度属性。
"""
import unittest
from pathlib import Path

P = Path(__file__).resolve().parent.parent
TOOL = (P / 'Tools' / 'CPUthermalDisplayTool.m').read_text()
CONTROL = (P / 'control').read_text()


class BattmanLimits(unittest.TestCase):
    def test_reads_virtual_brightness_limits(self):
        self.assertIn('@"VirtualBrightnessLimits"', TOOL)
        self.assertIn('@"UserAccessibleMaxNits"', TOOL)
        self.assertIn('@"HardwareAccessibleMaxNits"', TOOL)
        self.assertIn('@"MinNitsAccessibleWithDigitalDimming"', TOOL)

    def test_hardware_max_is_a_hard_ceiling(self):
        body = TOOL.split('double guardTarget = requested;', 1)[1].split('\n\n', 1)[0]
        self.assertIn('limits.hardwareMax > 0 && guardTarget > limits.hardwareMax', body)

    def test_device_guard_restores_before_learning(self):
        guard = TOOL.split('// 2.5) 机型守护', 1)[1].split('// 3) 纠正被压暗的面板亮度级。', 1)[0]
        self.assertIn('deviceGuarded', guard)
        self.assertIn('RaiseLevel(level, guardTarget, requested);', guard)
        self.assertIn('kDisplayCorrectionCooldown', guard)


class PanelTemperature(unittest.TestCase):
    def test_reads_iomfb_block_zero(self):
        self.assertIn('IOMobileFramebufferGetBlock', TOOL)
        self.assertIn('block[0] == 3', TOOL)
        self.assertIn('block[92]', TOOL)
        self.assertIn('block[0] == 1', TOOL)
        self.assertIn('block[84]', TOOL)

    def test_falls_back_to_registry_temperature(self):
        self.assertIn('CPUthermalRegistryPanelTemperature', TOOL)
        self.assertIn('APTPDCTemperature', TOOL)

    def test_temperature_is_read_only(self):
        body = TOOL.split('static double PanelHardwareTemperatureC(void) {', 1)[1].split('\n}', 1)[0]
        self.assertNotIn('SetCFProperty', body)
        self.assertNotIn('setProperty', body)

    def test_temperature_reaches_logs(self):
        self.assertIn('panelTemp=%{public}.2f', TOOL)


class Version(unittest.TestCase):
    def test_version(self):
        self.assertIn('Version: 1.6.2-173+isolation.60', CONTROL)


if __name__ == '__main__':
    unittest.main()
