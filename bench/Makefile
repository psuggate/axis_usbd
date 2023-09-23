.PHONY:	all build clean
all:	build

#
#  Icarus Verilog settings
##
IVC	?= iverilog
OPT	:= -g2005-sv -D__icarus -Wall

RTL	:= ../rtl
ARCH	= $(wildcard $(RTL)/arch/*.v)
FIFO	= $(wildcard $(RTL)/fifo/*.v)
USB	= $(wildcard $(RTL)/usb/*.v)
LIB	= $(ARCH) $(FIFO) $(USB)

BENCH	?= $(wildcard *_tb.v)
OUT	:= $(BENCH:%.v=../build/%.out)

build:	$(OUT)

../build/%.out: %.v $(LIB)
	$(IVC) $(OPT) -o $@ -s $(*F) $^
