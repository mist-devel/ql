// QL RAM timing simulation
//
// Much of the original QL RAM is used to generate the video signal. This module tries to slow
// down the SDRAM access similarly to the original timing

module ql_timing
(
	input			clk_sys,
	input  		reset,
	input			enable,
	input			ce_bus_p,
	
	input			cpu_uds,
	input			cpu_lds,
	
	input			sdram_wr,
	input			sdram_oe,

	input 		mdv_active,

	output reg	ram_delay_dtack
);


typedef enum reg [2:0] {
	STATE_IDLE				= 3'd0,
	STATE_WAIT_16BIT		= 3'd1,
	STATE_WAIT_NEXT		= 3'd2,
	STATE_DTACK_CLEAR		= 3'd3,
	STATE_HOLD				= 3'd4
	
} ram_delay_state_t;

ram_delay_state_t ram_delay_state;

always @(posedge clk_sys)
begin
	if (reset || !enable)
	begin
		ram_delay_dtack <= 0;
		ram_delay_state <= STATE_IDLE;
	end else
	begin

		//Breaks microdrives so disable DTACK.
		if (mdv_active) begin
			ram_delay_dtack <= 0;
			ram_delay_state = STATE_IDLE;
		end
	
		if (ce_bus_p && !mdv_active)
		begin

			case (ram_delay_state)
			STATE_IDLE:
				begin
					if (cpu_uds && cpu_lds)
						// 16-bit accesses must be delayed a whole slot more as the QL only had an 8-bit bus
						ram_delay_state <= STATE_WAIT_16BIT;
					else begin
						ram_delay_state <= STATE_WAIT_NEXT;
					end
					ram_delay_dtack <= 1;
				end
			
			// now uds/lds are also set for write accesses
			STATE_WAIT_16BIT:
				ram_delay_state <= STATE_WAIT_NEXT;			
							
			// Wait for next slot to start
			STATE_WAIT_NEXT:
				ram_delay_state <= STATE_DTACK_CLEAR;
			
			// Stop delaying DTACK
			STATE_DTACK_CLEAR:
				begin
					ram_delay_dtack <= 0;
					ram_delay_state <= STATE_HOLD;
				end	
				
			// Give CPU more time
			STATE_HOLD:
				ram_delay_state <= STATE_IDLE;
	
			endcase
		end
	end
end

endmodule
