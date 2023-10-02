.PHONY:	sim upload
upload:
	openFPGALoader --board tangprimer20k --write-sram impl/pnr/tang-usb.fs 

OPT	:= -g2005-sv -D__icarus -Wall

SRC	:= $(wildcard *.v)
RTL	:= $(filter-out %_tb.v, $(SRC))
TB	:= $(filter %_tb.v, $(SRC))
OUT	:= $(TB:%.v=%.out)
VCD	:= $(OUT:%.out=%.vcd)

sim:	$(VCD)

%.out:	%.v $(RTL)
	iverilog $(OPT) -o $@ -s $(*F) $^

%.vcd:	%.out
	./$<
