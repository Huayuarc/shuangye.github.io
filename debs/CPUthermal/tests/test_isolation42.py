"""isolation.42 契约：roothide 构建必须让 ApelinBootstrap.h 走 jbroot 分支，否则 Hello 120Hz 写不回注入设置。"""
import unittest
from pathlib import Path

P = Path(__file__).resolve().parents[1]
MAKEFILE = (P / 'Makefile').read_text()
HEADER = (P / 'include/ApelinBootstrap.h').read_text()
H120 = (P / 'Hello120Hz/Shared/H120Preferences.mm').read_text()


class BootstrapMacroContracts(unittest.TestCase):
    def test_header_accepts_theos_roothide_macro(self):
        # Theos 只导出 THEOS_PACKAGE_SCHEME_ROOTHIDE；头文件必须认它。
        self.assertIn('defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)', HEADER)
        self.assertIn('hasPrefix:@".jbroot-"', HEADER)

    def test_makefile_defines_scheme_macros(self):
        self.assertIn('ifeq ($(THEOS_PACKAGE_SCHEME),roothide)', MAKEFILE)
        self.assertIn('export ADDITIONAL_CFLAGS += -DAPELIN_BOOTSTRAP_ROOTHIDE=1', MAKEFILE)
        self.assertIn('export ADDITIONAL_CFLAGS += -DAPELIN_BOOTSTRAP_ROOTLESS=1', MAKEFILE)

    def test_hello120_uses_bootstrap_resolution(self):
        self.assertIn('#include <ApelinBootstrap.h>', H120)
        self.assertIn('ApelinBootstrapPath(logicalPath)', H120)
        self.assertNotIn('/var/jb', H120)


if __name__ == '__main__':
    unittest.main()
