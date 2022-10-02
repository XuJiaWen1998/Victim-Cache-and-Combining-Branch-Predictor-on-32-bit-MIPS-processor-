
module branch_predictor_global_predictor (
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// Request
	input logic i_req_valid,
	input logic [`ADDR_WIDTH - 1 : 0] i_req_pc,
	input logic [`ADDR_WIDTH - 1 : 0] i_req_target,
	output mips_core_pkg::BranchOutcome o_req_prediction,

	// Feedback
	input logic i_fb_valid,
	input logic [`ADDR_WIDTH - 1 : 0] i_fb_pc,
	input mips_core_pkg::BranchOutcome i_fb_prediction,
	input mips_core_pkg::BranchOutcome i_fb_outcome
);

	logic [1:0] counter[512];
	logic [8:0] old_gr;
	logic [8:0] new_gr;

	shift_register #(.N(9)) sh_reg(
		.bit_input(i_fb_outcome),
		.en(i_fb_valid), 
		.clk(clk),
		.reset(~rst_n),
		.old_output(old_gr),
		.new_output(new_gr)
	);

	always_ff @(posedge clk)
	begin
		if(~rst_n)
		begin
			for (int i = 0; i < 512; i++) begin
				counter[i] = 2'b10;	// Weakly taken			
			end
		end
		else
		begin
			if (i_fb_valid)
			begin
				case (i_fb_outcome)
					NOT_TAKEN:
								//decr shift register
								if (counter[old_gr] != 2'b00)
									counter[old_gr] <= counter[old_gr] - 2'b01;
					TAKEN:   	
								//incr shift register
								if (counter[old_gr] != 2'b11)
									counter[old_gr] <= counter[old_gr] + 2'b01;
				endcase
			end
		end
	end

	always_comb
	begin
		o_req_prediction = counter[new_gr][1] ? TAKEN : NOT_TAKEN;
	end

endmodule