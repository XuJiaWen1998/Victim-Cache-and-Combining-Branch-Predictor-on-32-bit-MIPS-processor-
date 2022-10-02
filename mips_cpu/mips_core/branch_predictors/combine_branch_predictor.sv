
module branch_predictor_combined(
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// Request
	input logic i_req_valid,
	input logic [`ADDR_WIDTH - 1 : 0] i_req_pc,
	input logic [`ADDR_WIDTH - 1 : 0] i_req_target,
	output mips_core_pkg::BranchOutcome o_req_prediction,
	output mips_core_pkg::BranchOutcome o_req_prediction1,
	output mips_core_pkg::BranchOutcome o_req_prediction2,

	// Feedback
	input logic i_fb_valid,
	input logic [`ADDR_WIDTH - 1 : 0] i_fb_pc,
	input mips_core_pkg::BranchOutcome i_fb_prediction,
	input mips_core_pkg::BranchOutcome i_fb_outcome,
	input mips_core_pkg::BranchOutcome i_fb_prediction1,
	input mips_core_pkg::BranchOutcome i_fb_prediction2
);
	logic 	   accuracy_1, accuracy_2, disagree;
	logic[1:0] counter, next_counter;
	assign accuracy_1 = (i_fb_prediction1 == i_fb_outcome);
	assign accuracy_2 = (i_fb_prediction1 == i_fb_outcome);
	assign disagree = (i_fb_prediction1 == i_fb_prediction2);

	always_comb begin
		if(~disagree) next_counter = counter;
		else if (accuracy_1) next_counter = (counter == 2'b00) ? counter : counter - 2'b01;
		else next_counter = (counter == 2'b11) ? counter : counter + 2'b01;
	end

	always_ff @(posedge clk) begin
		if (~rst_n) counter <= 2'b01; 
		else counter <= next_counter;
	end
	assign o_req_prediction = (counter[1] == 0) ? o_req_prediction1 : o_req_prediction2;

	branch_predictor_local_predictior PREDICTOR1 (
		.clk(clk), .rst_n(rst_n),

		.i_req_valid     (i_req_valid),
		.i_req_pc        (i_req_pc),
		.i_req_target    (i_req_target),
		.o_req_prediction(o_req_prediction1),

		.i_fb_valid      (i_fb_valid),
		.i_fb_pc         (i_fb_pc),
		.i_fb_prediction (i_fb_prediction),
		.i_fb_outcome    (i_fb_outcome)
	);
	branch_predictor_global_predictor_index  PREDICTOR2 (
		.clk(clk), .rst_n(rst_n),
		.i_req_valid     (i_req_valid),
		.i_req_pc        (i_req_pc),
		.i_req_target    (i_req_target),
		.o_req_prediction(o_req_prediction2),

		.i_fb_valid      (i_fb_valid),
		.i_fb_pc         (i_fb_pc),
		.i_fb_prediction (i_fb_prediction),
		.i_fb_outcome    (i_fb_outcome)
	);
endmodule