module branch_predictor_bimodal (
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
	logic [8:0] index;
	assign index = i_req_pc[8:0];
	task incr;
		begin
			if (counter[index] != 2'b11)
				counter[index] <= counter[index] + 2'b01;
		end
	endtask

	task decr;
		begin
			if (counter[index] != 2'b00)
				counter[index] <= counter[index] - 2'b01;
		end
	endtask

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
					NOT_TAKEN: decr();
					TAKEN:     incr();
				endcase
			end
		end
	end

	always_comb
	begin
		o_req_prediction = counter[index][1] ? TAKEN : NOT_TAKEN;
	end

endmodule