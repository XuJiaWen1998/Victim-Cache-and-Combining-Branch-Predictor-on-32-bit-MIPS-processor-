/*
 * branch_controller.sv
 * Author: Zinsser Zhang
 * Last Revision: 04/08/2018
 *
 * branch_controller is a bridge between branch predictor to hazard controller.
 * Two simple predictors are also provided as examples.
 *
 * See wiki page "Branch and Jump" for details.
 */
`include "mips_core.svh"

module branch_controller (
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// Request
	pc_ifc.in dec_pc,
	branch_decoded_ifc.hazard dec_branch_decoded,

	// Feedback
	pc_ifc.in ex_pc,
	branch_result_ifc.in ex_branch_result
);
	logic request_prediction;

		// Change the following line to switch predictor
		branch_predictor_combined PREDICTOR (
			.clk, .rst_n,

			.i_req_valid      (request_prediction),
			.i_req_pc         (dec_pc.pc),
			.i_req_target     (dec_branch_decoded.target),
			.o_req_prediction (dec_branch_decoded.prediction),
			.o_req_prediction1(dec_branch_decoded.prediction1),
			.o_req_prediction2(dec_branch_decoded.prediction2),
			.i_fb_outcome	 (ex_branch_result.outcome),
			.i_fb_valid      (ex_branch_result.valid),
			.i_fb_pc         (ex_pc.pc),
			.i_fb_prediction (ex_branch_result.prediction),
			.i_fb_prediction1(ex_branch_result.prediction1),
			.i_fb_prediction2(ex_branch_result.prediction2)
		);

	always_comb
	begin
		request_prediction = dec_branch_decoded.valid & ~dec_branch_decoded.is_jump;
		dec_branch_decoded.recovery_target =
			(dec_branch_decoded.prediction == TAKEN)
			? dec_pc.pc + `ADDR_WIDTH'd8
			: dec_branch_decoded.target;
	end

endmodule

module branch_predictor_always_not_taken (
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

	always_comb
	begin
		o_req_prediction = NOT_TAKEN;
	end

endmodule

module branch_predictor_2bit (
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

	logic [1:0] counter;

	task incr;
		begin
			if (counter != 2'b11)
				counter <= counter + 2'b01;
		end
	endtask

	task decr;
		begin
			if (counter != 2'b00)
				counter <= counter - 2'b01;
		end
	endtask

	always_ff @(posedge clk)
	begin
		if(~rst_n)
		begin
			counter <= 2'b01;	// Weakly not taken
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
		o_req_prediction = counter[1] ? TAKEN : NOT_TAKEN;
	end

endmodule


/// Code below has been move to the branch_predictors folder
/*
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

module branch_predictor_global_predictor_index (
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
	logic [7:0] new_gr;
	logic [7:0] old_gr;
	logic [7:0] old_index;
	logic [7:0] new_index;
	logic [7:0] index_sel;
	logic [7:0] index_sel_old;
	shift_register #(.N(8)) sh_reg(
		.bit_input(i_fb_outcome),
		.en(i_fb_valid), 
		.clk(clk),
		.reset(~rst_n),
		.old_output(old_gr),
		.new_output(new_gr)
	);
	assign old_index = i_fb_pc[7:0]; 
	assign new_index = i_req_pc[7:0];
	assign index_sel = {new_gr[7:4], new_index[7:4]};
	assign index_sel_old = {old_gr[7:4], old_index[7:4]};
	always_ff @(posedge clk)
	begin
		if(~rst_n)
		begin
			for (int i = 0; i < 512; i++) begin
				counter[i] = 2'b10;	// Weakly taken
			end
		end
		else
		if (i_fb_valid)
		begin
			case (i_fb_outcome)
				NOT_TAKEN:
				begin
							//decr shift register
							if (counter[index_sel_old] != 2'b00)
								counter[index_sel_old] <= counter[index_sel_old] - 2'b01;
				end
				TAKEN:  
				begin 	
							//incr shift register				
							if (counter[index_sel_old] != 2'b11)
								counter[index_sel_old] <= counter[index_sel_old] + 2'b01;
				end
			endcase
		end
	end


	always_comb
	begin
		o_req_prediction = counter[index_sel][1] ? TAKEN : NOT_TAKEN;
	end

endmodule


module branch_predictor_global_predictor_share (
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
	input mips_core_pkg::BranchOutcome i_fb_outcome[3]
);

	logic [1:0] counter[512];
	logic [7:0] new_gr;
	logic [7:0] old_gr;
	logic [7:0] old_index;
	logic [7:0] new_index;
	logic [7:0] index_sel;

	shift_register #(.N(8)) sh_reg(
		.bit_input(i_fb_outcome),
		.en(i_fb_valid), 
		.clk(clk),
		.reset(~rst_n),
		.old_output(old_gr),
		.new_output(new_gr)
	);
	assign old_index = i_fb_pc[7:0];
	assign new_index = i_req_pc[7:0];
	assign index_sel = new_gr ^ new_index;
	assign index_sel_old = old_gr ^ old_index;
	always_ff @(posedge clk)
	begin
		if(~rst_n)
		begin
			for (int i = 0; i < 512; i++) begin
				counter[i] = 2'b10;	// Weakly taken
			end
		end
		else begin
			if (i_fb_valid)
			begin
				case (i_fb_outcome)
					NOT_TAKEN:
					begin
								//decr shift register
								if (counter[index_sel_old] != 2'b00)
									counter[index_sel_old] <= counter[index_sel_old] - 2'b01;
					end
					TAKEN:  
					begin 	
								//incr shift register				
								if (counter[index_sel_old] != 2'b11)
									counter[index_sel_old] <= counter[index_sel_old] + 2'b01;
					end
				endcase
			end
		end
	end

	always_comb
	begin
		o_req_prediction = counter[index_sel][1] ? TAKEN : NOT_TAKEN;
	end

endmodule


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

module shift_register #(parameter N=9) (
	input bit_input,
	input clk,
	input reset,
	input en,
	output logic[N-1:0] old_output,
	output logic[N-1:0] new_output	
);
	logic[N-1:0] shift_reg;
	always_ff@(posedge clk) begin
		if(reset) shift_reg <= 0;
		else if(en) begin
			old_output <= shift_reg;
			new_output <= {bit_input, shift_reg[N-1:1]};
			shift_reg <= {bit_input, shift_reg[N-1:1]};
		end
		else begin
			new_output <= shift_reg;
			old_output <= shift_reg;
		end
	end
endmodule
*/