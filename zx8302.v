//
// zx8302.v
//
// ZX8302 for Sinclair QL for the MiST
// https://github.com/mist-devel
// 
// Copyright (c) 2015 Till Harbaum <till@harbaum.org> 
// Copyright (c) 2021 Daniele Terdina
// 
// This source file is free software: you can redistribute it and/or modify 
// it under the terms of the GNU General Public License as published 
// by the Free Software Foundation, either version 3 of the License, or 
// (at your option) any later version. 
// 
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>. 
//

module zx8302 (
		input          clk,       // 21 mhz
		input          clk_sys,   // 27 MHz board clock
      input          reset,
      input          init,
		
		// interrupts
		output [1:0]   ipl,
		input          xint,
		
		// sdram interface for microdrive emulation
		output [24:0]  mdv_addr,
		output [24:0]  mdv2_addr,
		input [15:0]   mdv_din,
		output         mdv_read,
		output         mdv2_read,
		input          mdv_men,
		input          video_cycle,

		// interface to watch MDV cartridge upload
		input [24:0]   mdv_dl_addr,
		input          mdv_download,
		input          mdv2_download,
		
		output 			mdv_seldrive,
		output			mdv_active,

		output         led,
		output         audio,
		
		// vertical synv 
		input          vs,

		// joysticks
		input [4:0]    js0,
		input [4:0]    js1,
		
		input          ps2_kbd_clk,
		input          ps2_kbd_data,
		
      // bus interface
		input				clk_bus,
		input				cpu_sel,
		input				cpu_wr,
		input [1:0] 	cpu_addr,      // a[5,1]
		input				cpu_uds,
		input				cpu_lds,
		input [15:0]   cpu_din,
		output [15:0]  cpu_dout
		
);


// comdata shift register
wire ipc_comdata_in = comdata_reg[0];
reg [3:0] comdata_reg /* synthesis noprune */;
reg [1:0] ipc_busy;
reg comdata_to_cpu;
reg prev_ipc_comctrl;


// ---------------------------------------------------------------------------------
// ----------------------------- CPU register write --------------------------------
// ---------------------------------------------------------------------------------

reg [7:0] mctrl;

// cpu is writing io registers
always @(negedge clk_bus) begin
	if (reset) begin
		comdata_reg <= 4'b0000;
		ipc_busy <= 2'b11;
	end
	irq_ack <= 5'd0;
	
	// cpu writes to 0x18XXX area
	if(cpu_sel && cpu_wr) begin
		// even addresses have uds asserted and use the upper 8 data bus bits
		if(cpu_uds) begin
			// cpu writes microdrive control register
			if(cpu_addr == 2'b10)
				mctrl <= cpu_din[15:8];
		end

		// odd addresses have lds asserted and use the lower 8 data bus bits
		if(cpu_lds) begin
			// 18003 - IPCWR
			// (host sends a single bit to ipc)
			if(cpu_addr == 2'b01) begin
				// data is ----XEDS
				// S = start bit (should be 0)
				// D = data bit (0/1)
				// E = stop bit (should be 1)
            // X = extra stopbit (should be 1)
				comdata_reg <= cpu_din[3:0];
				ipc_busy <= 2'b11;		// Show IPC BUSY until the IPC asserts COMCTL twice
         end

			// cpu writes interrupt register
			if(cpu_addr == 2'b10) begin
				irq_mask <= cpu_din[7:5];
				irq_ack <= cpu_din[4:0];
			end
		end
	end
	if (!ipc_comctrl && prev_ipc_comctrl) begin
		comdata_to_cpu <= zx8302_comdata_in;	// Latch COMDATA since the IPC will quickly reset it to 1 when sending data
		comdata_reg <= { 1'b1, comdata_reg[3:1] };
		ipc_busy <= { 1'b0, ipc_busy[1] };
	end
	prev_ipc_comctrl <= ipc_comctrl;
end

// ---------------------------------------------------------------------------------
// ----------------------------- CPU register read ---------------------------------
// ---------------------------------------------------------------------------------

// status register read
// bit 0       Network port
// bit 1       Transmit buffer full
// bit 2       Receive buffer full
// bit 3       Microdrive GAP
// bit 4       SER1 DTR
// bit 5       SER2 CTS
// bit 6       IPC busy
// bit 7       COMDATA

wire [7:0] io_status = { comdata_to_cpu, ipc_busy[0], 2'b00,
		(mdv_seldrive?mdv2_gap:mdv_gap), 
		(mdv_seldrive?mdv2_rx_ready:mdv_rx_ready), 
		(mdv_seldrive?mdv2_tx_empty:mdv_tx_empty), 1'b0 };
		
assign cpu_dout =
	// 18000/18001 and 18002/18003
	(cpu_addr == 2'b00)?rtc[47:32]:
	(cpu_addr == 2'b01)?rtc[31:16]:

	// 18020/18021 and 18022/18023
	(cpu_addr == 2'b10)?{io_status, irq_pending}:
	(cpu_addr == 2'b11)?(mdv_seldrive?{mdv2_byte, mdv2_byte}:{mdv_byte, mdv_byte}):

	16'h0000;	

// ---------------------------------------------------------------------------------
// -------------------------------------- IPC --------------------------------------
// ---------------------------------------------------------------------------------
	
wire ipc_comctrl;
wire ipc_comdata_out;

// 8302 sees its own comdata as well as the one from the ipc
wire zx8302_comdata_in = ipc_comdata_in && ipc_comdata_out;



wire [1:0] ipc_ipl;

ipc ipc (	
	.reset    	    ( reset          ),
	.clk_sys        ( clk_sys        ),   // 27 MHz board clock

	.comctrl        ( ipc_comctrl    ),
	.comdata_in     ( ipc_comdata_in ),
	.comdata_out    ( ipc_comdata_out),

   .audio          ( audio          ),
	.ipl            ( ipc_ipl        ),

	.js0            ( js0            ),
	.js1            ( js1            ),
	
	.ps2_kbd_clk    ( ps2_kbd_clk    ),
	.ps2_kbd_data   ( ps2_kbd_data   )
);

// ---------------------------------------------------------------------------------
// -------------------------------------- IRQs -------------------------------------
// ---------------------------------------------------------------------------------

wire [7:0] irq_pending = {1'b0, (mdv_sel == 0), clk64k, xint_irq, vsync_irq, 1'b0, 1'b0, gap_irq };
reg [2:0] irq_mask;
reg [4:0] irq_ack;

// any pending irq raises ipl to 2 and the ipc can control both ipl lines
assign ipl = { ipc_ipl[1] && (irq_pending[4:0] == 0), ipc_ipl[0] };

// vsync irq is set whenever vsync rises
reg vsync_irq;
wire vsync_irq_reset = reset || irq_ack[3];
always @(posedge clk) begin
	reg old_vs;
	
	old_vs <= vs;
	if(vsync_irq_reset)   vsync_irq <= 1'b0;
	else if(~old_vs & vs) vsync_irq <= 1'b1;
end

// toggling the mask will also trigger irqs ...
wire gap_irq_in = (mdv_seldrive?mdv2_gap:mdv_gap) && irq_mask[0];
reg gap_irq;
wire gap_irq_reset = reset || irq_ack[0];
always @(posedge clk) begin
	reg old_irq;
	
	old_irq <= gap_irq_in;
	if(gap_irq_reset)              gap_irq <= 1'b0;
	else if(~old_irq & gap_irq_in) gap_irq <= 1'b1;
end

// toggling the mask will also trigger irqs ...
wire xint_irq_in = xint && irq_mask[2];
reg xint_irq;
wire xint_irq_reset = reset || irq_ack[4];
always @(posedge clk) begin
	reg old_irq;
	
	old_irq <= xint_irq_in;
	if(xint_irq_reset)              xint_irq <= 1'b0;
	else if(~old_irq & xint_irq_in) xint_irq <= 1'b1;
end


// ---------------------------------------------------------------------------------
// ----------------------------------- microdrive ----------------------------------
// ---------------------------------------------------------------------------------

wire mdv_gap;
wire mdv2_gap;
wire mdv_tx_empty;
wire mdv2_tx_empty;
wire mdv_rx_ready;
wire mdv2_rx_ready;
wire [7:0] mdv_byte;
wire [7:0] mdv2_byte;

assign led = !(mdv_sel[0] || mdv_sel[1]);

mdv mdv (
   .clk      ( clk          ),
	.reset    ( init         ),
	
   .mdv_drive (1),		//This is MDV1_
   
	.sel      ( mdv_sel[0]   ),

   // control bits	
	.gap      ( mdv_gap      ),
	.tx_empty ( mdv_tx_empty ),
	.rx_ready ( mdv_rx_ready ),
	.dout     ( mdv_byte     ),
	
	.download ( mdv_download ),
	.dl_addr  ( mdv_dl_addr  ),

	// ram interface to read image
   .mem_ena  ( mdv_men      ),
   .mem_cycle( video_cycle  ),
	.mem_clk  ( clk_bus      ),
	.mem_addr ( mdv_addr     ),
	.mem_read ( mdv_read     ),  
	.mem_din  ( mdv_din      )	
);

mdv mdv2 (
   .clk      ( clk          ),
	.reset    ( init         ),
   
   .mdv_drive ( 2 ),		//This is MDV2_
	
   .sel      ( mdv_sel[1]   ),

   // control bits	
	.gap      ( mdv2_gap      ),
	.tx_empty ( mdv2_tx_empty ),
	.rx_ready ( mdv2_rx_ready ),
	.dout     ( mdv2_byte     ),
	
	.download ( mdv2_download ),
	.dl_addr  ( mdv_dl_addr  ),

	// ram interface to read image
   .mem_ena  ( mdv_men      ),
   .mem_cycle( video_cycle  ),
	.mem_clk  ( clk_bus      ),
	.mem_addr ( mdv2_addr     ),
	.mem_read ( mdv2_read     ),  

	.mem_din  ( mdv_din      )	
);

// the microdrive control register mctrl generates the drive selection
// mdv_sel = 1 for mdv1_, mdv_sel = 2 for mdv2_
reg [7:0] mdv_sel;
always @(posedge clk) begin
	reg old_mctrl;
	
	old_mctrl <= mctrl[1];
	if(old_mctrl & ~mctrl[1]) mdv_sel <= { mdv_sel[6:0], mctrl[0] };
end

// 0 for MDV1_ or nothing and 1 for MDV2_
// Only one microdrive can be accessed at a time, this allows
// switching between them.
assign mdv_seldrive = mdv_sel[1]?1'b1:1'b0;
assign mdv_active = mdv_sel[1] || mdv_sel[0];

// ---------------------------------------------------------------------------------
// -------------------------------------- RTC --------------------------------------
// ---------------------------------------------------------------------------------

// PLL for the real time clock (rtc)
reg [47:0] rtc;
always @(posedge clk64k)
	rtc <= rtc + 48'd1;

wire clk64k;
pll_rtc pll_rtc (
	 .inclk0(clk_sys),
	 .c0(clk64k)           // 65536Hz
);

	
endmodule
