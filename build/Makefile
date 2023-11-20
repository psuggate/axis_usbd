.PHONY:	all sim clean
all:	sim

OUT	:= $(wildcard *_tb.out)
VCD	:= $(OUT:%.out=%.vcd)

sim:	$(VCD)

clean:
	rm -f $(OUT)

%.vcd: %.out
	./$<
