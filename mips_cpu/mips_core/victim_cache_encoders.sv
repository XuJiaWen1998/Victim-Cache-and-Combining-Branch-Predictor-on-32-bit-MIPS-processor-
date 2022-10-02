module encoder_128bit (
	input logic[127:0] i_string,
	output logic[6:0] o_index,
	output logic o_valid
);
	logic o_valid1, o_valid2;
	logic[6:0] o_index1, o_index2;
	assign o_valid = o_valid1 ^ o_valid2;
	assign o_index = (o_valid1)? o_index1 : (o_index2 + 64);
	encoder_64bit encoder_64_1(
		.i_string(i_string[63:0]),
		.o_index(o_index1),
		.o_valid(o_valid1)
	);
	encoder_64bit encoder_64_2(
		.i_string(i_string[127:64]),
		.o_index(o_index2),
		.o_valid(o_valid2)
	);
endmodule
module encoder_64bit (
	input logic[63:0] i_string,
	output logic[5:0] o_index,
	output logic o_valid
);
	logic o_valid1, o_valid2;
	logic[5:0] o_index1, o_index2;
	assign o_valid = o_valid1 ^ o_valid2;
	assign o_index = (o_valid1)? o_index1 : (o_index2 + 32);
	encoder_32bit encoder_32_1(
		.i_string(i_string[31:0]),
		.o_index(o_index1),
		.o_valid(o_valid1)
	);
	encoder_32bit encoder_32_2(
		.i_string(i_string[63:32]),
		.o_index(o_index2),
		.o_valid(o_valid2)
	);
endmodule
module encoder_32bit (
	input logic[31:0] i_string,
	output logic[4:0] o_index,
	output logic o_valid
);
	logic o_valid1, o_valid2;
	logic[4:0] o_index1, o_index2;
	assign o_valid = o_valid1 ^ o_valid2;
	assign o_index = (o_valid1)? o_index1 : (o_index2 + 16);
	encoder_16bit encoder_16_1(
		.i_string(i_string[15:0]),
		.o_index(o_index1),
		.o_valid(o_valid1)
	);
	encoder_16bit encoder_16_2(
		.i_string(i_string[31:16]),
		.o_index(o_index2),
		.o_valid(o_valid2)
	);
endmodule
module encoder_16bit (
	input logic[15:0] i_string,
	output logic[3:0] o_index,
	output logic o_valid
);
	always_comb begin
		case(i_string)
			16'b0000_0000_0000_0001: 
			begin
				o_index = 0;
				o_valid = 1;
			end 
			16'b0000_0000_0000_0010:
			begin
				o_index = 1;
				o_valid = 1;
			end 
			16'b0000_0000_0000_0100:
			begin
				o_index = 2;
				o_valid = 1;
			end 
			16'b0000_0000_0000_1000:
			begin
				o_index = 3;
				o_valid = 1;
			end 
			16'b0000_0000_0001_0000:
			begin
				o_index = 4;
				o_valid = 1;
			end 
			16'b0000_0000_0010_0000:
			begin
				o_index = 5;
				o_valid = 1;
			end 
			16'b0000_0000_0100_0000:
			begin
				o_index = 6;
				o_valid = 1;
			end 
			16'b0000_0000_1000_0000:
			begin
				o_index = 7;
				o_valid = 1;
			end 
			16'b0000_0001_0000_0000:
			begin
				o_index = 8;
				o_valid = 1;
			end 
			16'b0000_0010_0000_0000:
			begin
				o_index = 9;
				o_valid = 1;
			end 
			16'b0000_0100_0000_0000:
			begin
				o_index = 10;
				o_valid = 1;
			end 
			16'b0000_1000_0000_0000:
			begin
				o_index = 11;
				o_valid = 1;
			end 
			16'b0001_0000_0000_0000:
			begin
				o_index = 12;
				o_valid = 1;
			end 
			16'b0010_0000_0000_0000:
			begin
				o_index = 13;
				o_valid = 1;
			end 
			16'b0100_0000_0000_0000:
			begin
				o_index = 14;
				o_valid = 1;
			end 
			16'b1000_0000_0000_0000:
			begin
				o_index = 15;
				o_valid = 1;
			end 
			default: 
			begin
				o_index = 0;
				o_valid = 0;
			end 
		endcase
	end

endmodule