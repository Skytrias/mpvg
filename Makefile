build:
# 	@../Odin/odin build client.odin -file -out:target/client -thread-count:12 -define:NANOVG_GL_IMPL=GL3 -use-separate-modules && cd target && ./client
	@../Odin/odin build src -out:target/test -thread-count:4 && cd target && ./test

# run:
# 	@cd target && ./client

# host_check:
# 	@../Odin/odin check host.odin -file -thread-count:12

# host_run:
# 	@../Odin/odin build host.odin -file -out:target/host -thread-count:12 -use-separate-modules && cd target && ./host

# debug:
# 	@../Odin/odin build client.odin -file -debug -out:target/client -thread-count:12 -define:NANOVG_GL_IMPL=GL3

# # check:
# # 	@../Odin/odin check src -thread-count:12