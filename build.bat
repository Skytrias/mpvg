@echo off
odin.exe build src -out:target/test.exe -thread-count:12 -debug && pushd target && test.exe && popd
rem odin.exe check src -thread-count:12
