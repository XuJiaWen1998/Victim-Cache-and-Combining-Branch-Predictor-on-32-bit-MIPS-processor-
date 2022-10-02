module stream_buffer #(
	parameter INDEX_WIDTH = 3,
	parameter BLOCK_OFFSET_WIDTH = 2
	) (
	// General signals
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low
    input logic i_we,
    input logic [`ADDR_WIDTH - 1 :  BLOCK_OFFSET_WIDTH + 2] i_raddr,
    input logic [`ADDR_WIDTH - 1 :  BLOCK_OFFSET_WIDTH + 2] i_waddr,
    input logic[`DATA_WIDTH - 1 : 0] i_wdata[1<<BLOCK_OFFSET_WIDTH],
    output logic o_buffer_hit,
    output logic[`DATA_WIDTH - 1 : 0] o_rdata[1<<BLOCK_OFFSET_WIDTH]
);

	localparam TAG_WIDTH = `ADDR_WIDTH - INDEX_WIDTH - BLOCK_OFFSET_WIDTH - 2;
	localparam LINE_SIZE = 1 << BLOCK_OFFSET_WIDTH;
	localparam DEPTH = 1 << INDEX_WIDTH;
	localparam CACHE_SIZE = 64;
    localparam CACHE_INDEX_SIZE = 6;
    logic[`DATA_WIDTH - 1 : 0]      data_table[CACHE_SIZE][LINE_SIZE];
    logic[`ADDR_WIDTH  - 1 : BLOCK_OFFSET_WIDTH + 2]     tag_table[CACHE_SIZE];

	logic [CACHE_SIZE - 1 : 0] output_compared_results, input_compared_results;
	logic [CACHE_SIZE - 1 : 0] valid_bits;
    logic [CACHE_INDEX_SIZE - 1: 0]  output_index, input_index, input_index_match;
    logic [CACHE_SIZE - 1 : 0] hit_index;
    always_ff@(posedge clk) begin
		if(~rst_n) begin
			valid_bits <= 0;
			input_index <= 0;
		end
        else if (i_we && ~(|(input_compared_results))) begin
            tag_table [input_index] <= i_waddr;
			for (int i = 0; i < LINE_SIZE; i++) begin
         		data_table[input_index][i] <= i_wdata[i];
			end
			valid_bits[input_index] <= 1;
			input_index <= (input_index == CACHE_SIZE - 1) ? 0 : input_index + 1;
		end
    end
	always_comb begin
		for (int i = 0; i < LINE_SIZE; i++) begin
         	o_rdata[i] = data_table[output_index][i];
		end
	end
	encoder_64bit output_encoder(
		.i_string(output_compared_results),
		.o_index(output_index),
		.o_valid(o_buffer_hit)
	);
	always_comb begin
		for(int i = 0; i < CACHE_SIZE; i++) begin
			output_compared_results[i] = valid_bits[i] & (i_raddr == tag_table[i]);
			input_compared_results[i] = valid_bits[i] & (i_waddr == tag_table[i]);
		end
	end
endmodule