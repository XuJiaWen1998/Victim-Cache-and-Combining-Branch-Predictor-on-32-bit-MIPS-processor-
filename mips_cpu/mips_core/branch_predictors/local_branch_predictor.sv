module branch_predictor_local_predictior (
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
	// adding a history table
	logic [10:0] history[2048];
	logic [10:0] history_index;
	// counter table
	logic [1:0] counter[2048];
	logic [10:0] old_index;
	logic [10:0] new_index;
	logic [10:0] old_counter_index;
	assign history_index = i_req_pc[10:0];
	assign old_index = i_fb_pc[10:0];
	assign new_index = history[history_index];
	assign old_counter_index = history[old_index];
	always_ff @(posedge clk) begin
		history[old_index] <= (i_fb_outcome == TAKEN) ? {1'b1, history[old_index][10:1]} : {1'b0, history[old_index][10:1]};
	end
	task incr;
		begin
			if (counter[old_counter_index] != 2'b11)
				counter[old_counter_index] <= counter[old_counter_index] + 2'b01;
		end
	endtask

	task decr;
		begin
			if (counter[old_counter_index] != 2'b00)
				counter[old_counter_index] <= counter[old_counter_index] - 2'b01;
		end
	endtask

	// counter table
	always_ff @(posedge clk)
	begin
		if(~rst_n)
		begin
			for (int i = 0; i < 2048; i++) begin
				counter[i] = 2'b10;	// Weakly take
				history[i] = 0;	//assume all non takenn
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
		o_req_prediction = counter[new_index][1] ? TAKEN : NOT_TAKEN;
	end

endmodule