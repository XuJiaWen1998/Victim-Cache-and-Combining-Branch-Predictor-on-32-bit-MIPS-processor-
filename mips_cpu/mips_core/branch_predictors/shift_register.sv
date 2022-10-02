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