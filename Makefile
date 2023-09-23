.PHONY:	all clean sim
all:
	@make -C bench all

sim:
	@make -C bench sim

clean:
	@make -C bench clean
