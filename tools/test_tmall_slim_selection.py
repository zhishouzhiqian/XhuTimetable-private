import tempfile
import unittest
from pathlib import Path
from build_tmall_slim_runtime import select_classes

class SlimSelectionTest(unittest.TestCase):
    def test_static_reflection_and_transitive_references(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            fixtures={
                'mtopsdk/security/InnerSignImpl': '.class Lmtopsdk/security/InnerSignImpl;\n.field value:Lsample/Direct;\nconst-string v0, "sample.Reflection"',
                'sample/Direct': '.class Lsample/Direct;\ninvoke-static {}, Lsample/Dependency;->call()V',
                'sample/Reflection': '.class Lsample/Reflection;',
                'sample/Dependency': '.class Lsample/Dependency;',
                'sample/Advertisement': '.class Lsample/Advertisement;',
            }
            for name,text in fixtures.items():
                p=root/(name+'.smali');p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text)
            _,selected=select_classes([root])
            self.assertEqual(selected,{'L'+n+';' for n in fixtures if n!='sample/Advertisement'})

if __name__=='__main__': unittest.main()
