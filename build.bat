@echo off
odin.exe build src -out:target/test.exe -thread-count:12 -define:TESTING=false && pushd target && test.exe && popd
rem odin.exe build src -out:target/test.exe -thread-count:12