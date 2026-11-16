import os
import shutil
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "libexec", "claudemeister", "lib"))
import claude_alias as a  # noqa: E402


class Alias(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        self.saved = os.environ.get("PATH"), a.HOME
        os.environ["PATH"] = self.bin + os.pathsep + "/usr/bin:/bin"
        a.HOME = self.tmp
        os.symlink(a.TARGET, os.path.join(self.bin, "claudemeister"))

    def tearDown(self):
        os.environ["PATH"], a.HOME = self.saved
        shutil.rmtree(self.tmp)

    def test_on_puts_cm_next_to_claudemeister_and_off_removes_it(self):
        self.assertFalse(a.enabled())
        self.assertEqual(a.main(["on"]), 0)
        self.assertTrue(a.enabled())
        self.assertEqual(os.path.dirname(a.found()), self.bin)
        self.assertEqual(a.main(["on"]), 0)
        self.assertEqual(a.main(["off"]), 0)
        self.assertFalse(os.path.lexists(os.path.join(self.bin, "cm")))

    def test_foreign_cm_is_left_alone(self):
        other = os.path.join(self.bin, "cm")
        with open(other, "w") as f:
            f.write("#!/bin/sh\n")
        os.chmod(other, 0o755)
        self.assertFalse(a.enabled())
        self.assertEqual(a.main(["on"]), 1)
        self.assertEqual(a.main(["off"]), 1)
        self.assertTrue(os.path.isfile(other) and not os.path.islink(other))

    def test_unknown_command(self):
        self.assertEqual(a.main(["sideways"]), 2)


if __name__ == "__main__":
    unittest.main()
