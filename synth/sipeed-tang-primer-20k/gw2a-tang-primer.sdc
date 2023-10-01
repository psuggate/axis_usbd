create_clock -name ulpi_clk -period 16.667 -waveform {0 5.75} [get_ports {ulpi_clk}]
create_clock -name clk_26 -period 37.037 -waveform {0 18.518} [get_ports {clk_26}]
set_clock_latency -source 0.4 [get_clocks {ulpi_clk}] 

create_clock -name clk_x1 -period 10 -waveform {0 5} [get_nets {clk_x1}]
create_clock -name clk_x4 -period 2.5 -waveform {0 1.25} [get_nets {ddr_clk}]
// create_clock -name clk -period 37.037 -waveform {0 18.518} [get_ports {clk}]

set_clock_groups -asynchronous -group [get_clocks {clk_x1}] -group [get_clocks {clk_x4}] -group [get_clocks {clk_26}]
report_timing -hold -from_clock [get_clocks {clk*}] -to_clock [get_clocks {clk*}] -max_paths 25 -max_common_paths 1
report_timing -setup -from_clock [get_clocks {clk*}] -to_clock [get_clocks {clk*}] -max_paths 25 -max_common_paths 1
