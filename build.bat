@echo off
rem odin.exe build src -out:target/test.exe -thread-count:12 && pushd target && test.exe && popd
odin.exe check src -thread-count:12
