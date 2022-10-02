/*
 * i_cache.sv
 * Author: Zinsser Zhang
 * Last Revision: 03/13/2022
 *
 * This is a direct-mapped instruction cache. Line size and depth (number of
 * lines) are set via INDEX_WIDTH and BLOCK_OFFSET_WIDTH parameters. Notice that
 * line size means number of words (each consist of 32 bit) in a line. Because
 * all addresses in mips_core are 26 byte addresses, so the sum of TAG_WIDTH,
 * INDEX_WIDTH and BLOCK_OFFSET_WIDTH is `ADDR_WIDTH - 2.
 *
 * Typical line sizes are from 2 words to 8 words. The memory interfaces only
 * support up to 8 words line size.
 *
 * Because we need a hit latency of 1 cycle, we need an asynchronous read port,
 * i.e. data is ready during the same cycle when address is calculated. However,
 * SRAMs only support synchronous read, i.e. data is ready the cycle after the
 * address is calculated. Due to this conflict, we need to read from the banks
 * on the clock edge at the beginning of the cycle. As a result, we need both
 * the registered version of address and a non-registered version of address
 * (which will effectively be registered in SRAM).
 *
 * See wiki page "Synchronous Caches" for details.
 */
`include "mips_core.svh"
module i_cache #(
	parameter INDEX_WIDTH = 5,
	parameter BLOCK_OFFSET_WIDTH = 2
	)(
	// General signals
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// Request
	pc_ifc.in i_pc_current,
	pc_ifc.in i_pc_next,

	// Response
	cache_output_ifc.out out,

	// Memory interface
	axi_read_address.master mem_read_address,
	axi_read_data.master mem_read_data
);
	localparam TAG_WIDTH = `ADDR_WIDTH - INDEX_WIDTH - BLOCK_OFFSET_WIDTH - 2;
	localparam LINE_SIZE = 1 << BLOCK_OFFSET_WIDTH;
	localparam DEPTH = 1 << INDEX_WIDTH;

	// Check if the parameters are set correctly
	generate
		if(TAG_WIDTH <= 0 || LINE_SIZE > 16)
		begin
			INVALID_I_CACHE_PARAM invalid_i_cache_param ();
		end
	endgenerate

	// Parsing
	logic [TAG_WIDTH - 1 : 0] i_tag;
	logic [INDEX_WIDTH - 1 : 0] i_index;
	logic [BLOCK_OFFSET_WIDTH - 1 : 0] i_block_offset;

	logic [INDEX_WIDTH - 1 : 0] i_index_next;

	assign {i_tag, i_index, i_block_offset} = i_pc_current.pc[`ADDR_WIDTH - 1 : 2];
	assign i_index_next = i_pc_next.pc[BLOCK_OFFSET_WIDTH + 2 +: INDEX_WIDTH];
	// Above line uses +: slice, a feature of SystemVerilog
	// See https://stackoverflow.com/questions/18067571

	// States
	enum logic[2:0] {
		STATE_READY,            // Ready for incoming requests
		STATE_REFILL_REQUEST,   // Sending out a memory read request
		STATE_REFILL_DATA,       // Missing on a read		
		STATE_VICTIM,
		STATE_STREAMBUFFER
	} state, next_state;

	// Registers for refilling
	logic [INDEX_WIDTH - 1:0] r_index;
	logic [TAG_WIDTH - 1:0] r_tag;

	// databank signals
	logic [LINE_SIZE - 1 : 0] databank_select;
	logic [LINE_SIZE - 1 : 0] databank_we;
	logic [`DATA_WIDTH - 1 : 0] databank_wdata;
	logic [INDEX_WIDTH - 1 : 0] databank_waddr;
	logic [INDEX_WIDTH - 1 : 0] databank_raddr;
	logic [`DATA_WIDTH - 1 : 0] databank_rdata [LINE_SIZE];

	// databanks
	genvar g;
	generate
		for (g = 0; g < LINE_SIZE; g++)
		begin : databanks
			cache_bank #(
				.DATA_WIDTH (`DATA_WIDTH),
				.ADDR_WIDTH (INDEX_WIDTH)
			) databank (
				.clk,
				.i_we (databank_we[g]),
				.i_wdata(databank_wdata),
				.i_waddr(databank_waddr),
				.i_raddr(databank_raddr),

				.o_rdata(databank_rdata[g])
			);
		end
	endgenerate

	// tagbank signals
	logic tagbank_we;
	logic [TAG_WIDTH - 1 : 0] tagbank_wdata;
	logic [INDEX_WIDTH - 1 : 0] tagbank_waddr;
	logic [INDEX_WIDTH - 1 : 0] tagbank_raddr;
	logic [TAG_WIDTH - 1 : 0] tagbank_rdata;

	cache_bank #(
		.DATA_WIDTH (TAG_WIDTH),
		.ADDR_WIDTH (INDEX_WIDTH)
	) tagbank (
		.clk,
		.i_we    (tagbank_we),
		.i_wdata (tagbank_wdata),
		.i_waddr (tagbank_waddr),
		.i_raddr (tagbank_raddr),

		.o_rdata (tagbank_rdata)
	);

	// Valid bits
	logic [DEPTH - 1 : 0] valid_bits;

	// Intermediate signals
	logic hit, miss;
	logic last_refill_word;

	// stream buffer logics
    logic sb_we, sb_re;
	logic sb_hit, sb_hit_temp;
	logic[`ADDR_WIDTH - 3 - BLOCK_OFFSET_WIDTH : 0] sb_raddr;
	logic[`ADDR_WIDTH - 3 - BLOCK_OFFSET_WIDTH : 0] sb_waddr;
	logic[`DATA_WIDTH - 1 : 0] sb_rdata [LINE_SIZE], sb_rdata_temp [LINE_SIZE];
	logic[`DATA_WIDTH - 1 : 0] sb_wdata [LINE_SIZE];
	logic[BLOCK_OFFSET_WIDTH - 1 : 0] sb_offset;
	logic[2:0] sb_counter;


	// stream buffer
	stream_buffer #(
		.INDEX_WIDTH(3),
		.BLOCK_OFFSET_WIDTH (2)
	) sb(
		.clk,
		.rst_n,
		.i_we(sb_we),
		.i_raddr(sb_raddr),
		.i_waddr(sb_waddr),
		.i_wdata(sb_wdata),
		.o_buffer_hit(sb_hit),
		.o_rdata(sb_rdata_temp)
	);
	always_comb begin
		sb_raddr = {i_tag, i_index};
		sb_wdata = databank_rdata;
		sb_waddr = {i_tag, i_index};
		sb_we = hit;
	end
    logic vt_we;
	logic vt_hit;
	logic[`ADDR_WIDTH - 3 - BLOCK_OFFSET_WIDTH : 0] vt_raddr;
	logic[`ADDR_WIDTH - 3 - BLOCK_OFFSET_WIDTH : 0] vt_waddr;
	logic[`DATA_WIDTH - 1 : 0] vt_rdata [LINE_SIZE], vt_rdata_temp [LINE_SIZE];
	logic[`DATA_WIDTH - 1 : 0] vt_wdata [LINE_SIZE];
	logic[BLOCK_OFFSET_WIDTH - 1 : 0] vt_offset;
	logic[2:0] vt_counter;

	// Shift registers for victim cache
	victim_cache_i #(
		.INDEX_WIDTH(3),
		.BLOCK_OFFSET_WIDTH (2)
	) vt_cache(
		.clk,
		.rst_n,
		.i_we(vt_we),
		.i_raddr(vt_raddr),
		.i_waddr(vt_waddr),
		.i_wdata(vt_wdata),
		.o_victim_hit(vt_hit),
		.o_rdata(vt_rdata_temp)
	);
	always_comb begin
		vt_raddr = {i_tag, i_index};
		vt_wdata = databank_rdata;
		vt_waddr = {tagbank_rdata, i_index};
		if (state == STATE_READY) begin
			if (i_tag != tagbank_rdata && valid_bits[i_index]) begin
				vt_we = 1;
			end
			else begin
				vt_we = 0;
			end
		end
		else begin 
			vt_we = 0;
		end
	end
	always_ff @(posedge clk) begin
		if (state == STATE_VICTIM) begin
			vt_counter <= vt_counter + 1;
		end
		else begin 
			vt_counter <= 0;
		end
		if (state == STATE_STREAMBUFFER) begin
			sb_counter <= sb_counter + 1;
		end
		else begin 
			sb_counter <= 0;
		end
	end
	always_comb
	begin
		hit = valid_bits[i_index]
			& (i_tag == tagbank_rdata)
			& (state == STATE_READY);
		miss = ~hit;
		last_refill_word = (databank_select[LINE_SIZE - 1] & mem_read_data.RVALID) 
							|| (state == STATE_VICTIM && vt_counter == LINE_SIZE
							|| (state == STATE_STREAMBUFFER && sb_counter == LINE_SIZE));
	
	end

	always_comb
	begin
		mem_read_address.ARADDR = {r_tag, r_index,
			{BLOCK_OFFSET_WIDTH + 2{1'b0}}};
		mem_read_address.ARLEN = LINE_SIZE;
		mem_read_address.ARVALID = state == STATE_REFILL_REQUEST;
		mem_read_address.ARID = 4'd0;

		// Always ready to consume data
		mem_read_data.RREADY = 1'b1;
	end

	always_comb
	begin
		if (mem_read_data.RVALID) begin
			databank_we = databank_select;
			databank_wdata = mem_read_data.RDATA;
		end		
		else if (state == STATE_VICTIM) begin
			databank_we = '0;
			databank_we[vt_counter] = 1'b1;
			databank_wdata = vt_rdata[vt_counter];
		end		
		else if (state == STATE_STREAMBUFFER) begin
			databank_we = '0;
			databank_we[sb_counter] = 1'b1;
			databank_wdata = sb_rdata[sb_counter];
		end
		else begin
			databank_we = '0;
			databank_wdata = mem_read_data.RDATA;
		end

		//databank_wdata = mem_read_data.RDATA;
		databank_waddr = r_index;
		databank_raddr = i_index_next;
	end

	always_comb
	begin
		tagbank_we = last_refill_word;
		tagbank_wdata = r_tag;
		tagbank_waddr = r_index;
		tagbank_raddr = i_index_next;
	end

	always_comb
	begin
		out.valid = hit;
		out.data = databank_rdata[i_block_offset];
		//$display("address: %0h, state:%0h, sb_hit: %0h, hit: %0h, sb_raddr: %0h, tag: %0h, tagbank: %0h, index: %0h", i_pc_current.pc, state, sb_hit, hit, sb_raddr, i_tag, tagbank_rdata, i_index);
	end
	always_comb

	begin
		next_state = state;
		unique case (state)
			STATE_READY:
				if (miss)
					if (vt_hit) begin
						next_state = STATE_VICTIM;
					end
					else if (sb_hit) begin
						next_state = STATE_STREAMBUFFER;
					end
					else next_state = STATE_REFILL_REQUEST;
			STATE_REFILL_REQUEST:
				if (mem_read_address.ARREADY)
					next_state = STATE_REFILL_DATA;
			STATE_REFILL_DATA:
				if (last_refill_word)
					next_state = STATE_READY;
			STATE_VICTIM:
				if (vt_counter == LINE_SIZE) next_state = STATE_READY;
				else next_state = STATE_VICTIM;
			STATE_STREAMBUFFER:
				if (sb_counter == LINE_SIZE) next_state = STATE_READY;
				else next_state = STATE_STREAMBUFFER;
		endcase
	end

	always_ff @(posedge clk)
	begin
		if(~rst_n)
		begin
			state <= STATE_READY;
			databank_select <= 1;
			valid_bits <= '0;
		end
		else
		begin
			state <= next_state;

			case (state)
				STATE_READY:
				begin
					if (miss)
					begin
						r_tag <= i_tag;
						r_index <= i_index;
						vt_rdata <= vt_rdata_temp;
						sb_rdata <= sb_rdata_temp;
					end
				end
				STATE_REFILL_REQUEST:
				begin
				end
				STATE_REFILL_DATA:
				begin
					if (mem_read_data.RVALID)
					begin
						databank_select <= {databank_select[LINE_SIZE - 2 : 0],
							databank_select[LINE_SIZE - 1]};
						valid_bits[r_index] <= last_refill_word;
					end
				end
			endcase
		end
	end
	/*
always_comb begin
	if (state == STATE_VICTIM) begin
		$display("out_data: %0h, state: %0h, vt_hit: %0h, hit: %0h", out.data, state, vt_hit, out.valid);	
		$display("tag: %0h, index: %0h, offset: %0h, %0h", i_tag, i_index, i_block_offset, {i_tag, i_index});
		$display("data: %0h, %0h, %0h, %0h", databank_rdata[0], databank_rdata[1], databank_rdata[2], databank_rdata[3]);
		$display("en: %0b, %0h, %0h, %0h", databank_we[0], databank_we[1], databank_we[2], databank_we[3]);
		$display("vt: %0h, %0h, %0h, %0h", vt_rdata[0], vt_rdata[1], vt_rdata[2], vt_rdata[3]);
		$display("vt: %0h, %0h, %0h, %0h", vt_rdata_temp[0], vt_rdata_temp[1], vt_rdata_temp[2], vt_rdata_temp[3]);
		$display("vt_we: %0h, vt_owe: %0h", vt_we, vt_owe);
	end
end*/
endmodule


///Code below has been moved to victim_cache.sv and victim_cache_encoders.sv
/*
module victim_cache_i #(
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
    output logic o_victim_hit,
    output logic[`DATA_WIDTH - 1 : 0] o_rdata[1<<BLOCK_OFFSET_WIDTH]
);

	localparam TAG_WIDTH = `ADDR_WIDTH - INDEX_WIDTH - BLOCK_OFFSET_WIDTH - 2;
	localparam LINE_SIZE = 1 << BLOCK_OFFSET_WIDTH;
	localparam DEPTH = 1 << INDEX_WIDTH;
	localparam CACHE_SIZE = 64;
    localparam CACHE_INDEX_SIZE = 6;
    // data table for victim cache
    logic[`DATA_WIDTH - 1 : 0]      data_table[CACHE_SIZE][LINE_SIZE];
    // tag table for victim cache
    logic[`ADDR_WIDTH  - 1 : BLOCK_OFFSET_WIDTH + 2]     tag_table[CACHE_SIZE];

	logic [CACHE_SIZE - 1 : 0] output_compared_results, input_compared_results;
	logic [CACHE_SIZE - 1 : 0] valid_bits;
    logic [CACHE_INDEX_SIZE - 1: 0]  output_index, input_index, input_index_match;
    logic [CACHE_SIZE - 1 : 0] hit_index;
    logic hit, i_victim_hit;
    // Write into Victim Cache
    always_ff@(posedge clk) begin
		if(~rst_n) begin
			valid_bits <= 0;
			input_index <= 0;
		end
        else if (i_we) begin
			if (i_victim_hit) begin
				tag_table [input_index_match] <= i_waddr;
				for (int i = 0; i < LINE_SIZE; i++) begin
         	    	data_table[input_index_match][i] <= i_wdata[i];
				end
				valid_bits[input_index_match] <= 1;
				input_index <= input_index;
			end
			else begin
            	tag_table [input_index] <= i_waddr;
				for (int i = 0; i < LINE_SIZE; i++) begin
         	    	data_table[input_index][i] <= i_wdata[i];
				end
				valid_bits[input_index] <= 1;
				input_index <= (input_index == CACHE_SIZE - 1) ? 0 : input_index + 1;
			end
        end
    end
	
	
	// Read from Victim Cache
	always_comb begin
		for (int i = 0; i < LINE_SIZE; i++) begin
         	o_rdata[i] = data_table[output_index][i];
		end
	end
	encoder_64bit_i output_encoder(
		.i_string(output_compared_results),
		.o_index(output_index),
		.o_valid(o_victim_hit)
	);
	encoder_64bit_i input_encoder(
		.i_string(input_compared_results),
		.o_index(input_index_match),
		.o_valid(i_victim_hit)
	);
	always_comb begin
		for(int i = 0; i < CACHE_SIZE; i++) begin
			output_compared_results[i] = valid_bits[i] & (i_raddr == tag_table[i]);
			input_compared_results[i] = valid_bits[i] & (i_waddr == tag_table[i]);
		end
	end
endmodule
module encoder_128bit_i (
	input logic[127:0] i_string,
	output logic[6:0] o_index,
	output logic o_valid
);
	logic o_valid1, o_valid2;
	logic[6:0] o_index1, o_index2;
	assign o_valid = o_valid1 ^ o_valid2;
	assign o_index = (o_valid1)? o_index1 : (o_index2 + 64);
	encoder_64bit_i encoder_64_1(
		.i_string(i_string[63:0]),
		.o_index(o_index1),
		.o_valid(o_valid1)
	);
	encoder_64bit_i encoder_64_2(
		.i_string(i_string[127:64]),
		.o_index(o_index2),
		.o_valid(o_valid2)
	);
endmodule
module encoder_64bit_i (
	input logic[63:0] i_string,
	output logic[5:0] o_index,
	output logic o_valid
);
	logic o_valid1, o_valid2;
	logic[5:0] o_index1, o_index2;
	assign o_valid = o_valid1 ^ o_valid2;
	assign o_index = (o_valid1)? o_index1 : (o_index2 + 32);
	encoder_32bit_i encoder_32_1(
		.i_string(i_string[31:0]),
		.o_index(o_index1),
		.o_valid(o_valid1)
	);
	encoder_32bit_i encoder_32_2(
		.i_string(i_string[63:32]),
		.o_index(o_index2),
		.o_valid(o_valid2)
	);
endmodule
module encoder_32bit_i (
	input logic[31:0] i_string,
	output logic[4:0] o_index,
	output logic o_valid
);
	logic o_valid1, o_valid2;
	logic[4:0] o_index1, o_index2;
	assign o_valid = o_valid1 ^ o_valid2;
	assign o_index = (o_valid1)? o_index1 : (o_index2 + 16);
	encoder_16bit_i encoder_16_1(
		.i_string(i_string[15:0]),
		.o_index(o_index1),
		.o_valid(o_valid1)
	);
	encoder_16bit_i encoder_16_2(
		.i_string(i_string[31:16]),
		.o_index(o_index2),
		.o_valid(o_valid2)
	);
endmodule
module encoder_16bit_i (
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


*/