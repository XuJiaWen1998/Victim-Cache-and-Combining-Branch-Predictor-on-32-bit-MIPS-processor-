

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