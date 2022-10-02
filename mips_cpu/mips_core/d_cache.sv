/*
 * d_cache.sv
 * Author: Zinsser Zhang
 * Last Revision: 03/13/2022
 *
 * This is a direct-mapped data cache. Line size and depth (number of lines) are
 * set via INDEX_WIDTH and BLOCK_OFFSET_WIDTH parameters. Notice that line size
 * means number of words (each consist of 32 bit) in a line. Because all
 * addresses in mips_core are 26 byte addresses, so the sum of TAG_WIDTH,
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
interface d_cache_input_ifc ();
	logic valid;
	mips_core_pkg::MemAccessType mem_action;
	logic [`ADDR_WIDTH - 1 : 0] addr;
	logic [`ADDR_WIDTH - 1 : 0] addr_next;
	logic [`DATA_WIDTH - 1 : 0] data;

	modport in  (input valid, mem_action, addr, addr_next, data);
	modport out (output valid, mem_action, addr, addr_next, data);
endinterface

module d_cache #(
	parameter INDEX_WIDTH = 3,
	parameter BLOCK_OFFSET_WIDTH = 2
	)(
	// General signals
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// Request
	d_cache_input_ifc.in in,

	// Response
	cache_output_ifc.out out,

	// AXI interfaces
	axi_write_address.master mem_write_address,
	axi_write_data.master mem_write_data,
	axi_write_response.master mem_write_response,
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
			INVALID_D_CACHE_PARAM invalid_d_cache_param ();
		end
	endgenerate

	// Parsing
	logic [TAG_WIDTH - 1 : 0] i_tag;
	logic [INDEX_WIDTH - 1 : 0] i_index;
	logic [BLOCK_OFFSET_WIDTH - 1 : 0] i_block_offset;

	logic [INDEX_WIDTH - 1 : 0] i_index_next;

	assign {i_tag, i_index, i_block_offset} = in.addr[`ADDR_WIDTH - 1 : 2];
	assign i_index_next = in.addr_next[BLOCK_OFFSET_WIDTH + 2 +: INDEX_WIDTH];
	// Above line uses +: slice, a feature of SystemVerilog
	// See https://stackoverflow.com/questions/18067571

	// States
	enum logic [2:0] {
		STATE_READY,            // Ready for incoming requests
		STATE_FLUSH_REQUEST,    // Sending out memory write request
		STATE_FLUSH_DATA,       // Writes out a dirty cache line
		STATE_REFILL_REQUEST,   // Sending out memory read request
		STATE_REFILL_DATA,
		       // Loads a cache line from memory
		STATE_VICTIM
	} state, next_state;
	logic pending_write_response;

	// Registers for flushing and refilling
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
	// Dirty bits
	logic [DEPTH - 1 : 0] dirty_bits;

	// Shift registers for flushing
	logic [`DATA_WIDTH - 1 : 0] shift_rdata[LINE_SIZE];

	// Intermediate signals
	logic hit, miss;
	logic last_flush_word;
	logic last_refill_word;
    logic vt_we, vt_owe;
	logic vt_hit;
	logic[`ADDR_WIDTH - 3 - BLOCK_OFFSET_WIDTH : 0] vt_raddr;
	logic[`ADDR_WIDTH - 3 - BLOCK_OFFSET_WIDTH : 0] vt_waddr;
	logic[`ADDR_WIDTH - 3 - BLOCK_OFFSET_WIDTH : 0] vt_owaddr;
	logic[`DATA_WIDTH - 1 : 0] vt_rdata [LINE_SIZE], vt_rdata_temp [LINE_SIZE];
	logic[`DATA_WIDTH - 1 : 0] vt_wdata [LINE_SIZE];
	logic[`DATA_WIDTH - 1 : 0] vt_owdata;
	logic[BLOCK_OFFSET_WIDTH - 1 : 0] vt_offset;

	// Shift registers for victim cache
	victim_cache_d #(
		.INDEX_WIDTH(3),
		.BLOCK_OFFSET_WIDTH (2)
	) vt_cache(
		.clk,
		.rst_n,
		.i_we(vt_we),
		.i_raddr(vt_raddr),
		.i_waddr(vt_waddr),
		.i_wdata(vt_wdata),
		.i_owdata(vt_owdata),
		.i_owaddr(vt_owaddr),
		.i_owoffset(vt_offset),
		.i_owe(vt_owe),
		.o_victim_hit(vt_hit),
		.o_rdata(vt_rdata_temp)
	);
	logic[2:0] vt_counter;
	always_comb begin
		vt_raddr = {i_tag, i_index};
		vt_wdata = databank_rdata;
		vt_owdata = in.data;
		vt_offset = i_block_offset;
		vt_owaddr = {i_tag, i_index};
		vt_waddr = {tagbank_rdata, i_index};
		if (state == STATE_READY && in.valid) begin
			// write the whole line from databank if miss
			if (i_tag != tagbank_rdata && valid_bits[i_index]) begin
				vt_we = 1;
			end
			else begin
				vt_we = 0;
			end
			// write one byte to victim cache if I want to store data
			if (in.mem_action == WRITE && vt_hit) begin
				vt_owe = 1;
			end
			else begin
				vt_owe = 0;
			end
		end
		else begin 
			vt_we = 0;
			vt_owe = 0;
		end
	end
	always_ff @(posedge clk) begin
		if (state == STATE_VICTIM) begin
			vt_counter <= vt_counter + 1;
		end
		else begin 
			vt_counter <= 0;
		end
	end

	always_comb
	begin
		hit = in.valid
			& valid_bits[i_index]
			& (i_tag == tagbank_rdata)
			& (state == STATE_READY);
		miss = in.valid & ~hit;
		last_flush_word = databank_select[LINE_SIZE - 1] & mem_write_data.WVALID;
		last_refill_word = (databank_select[LINE_SIZE - 1] & mem_read_data.RVALID) || (state == STATE_VICTIM && vt_counter == LINE_SIZE);
	end

	always_comb
	begin
		mem_write_address.AWVALID = state == STATE_FLUSH_REQUEST;
		mem_write_address.AWID = 0;
		mem_write_address.AWLEN = LINE_SIZE;
		mem_write_address.AWADDR = {tagbank_rdata, i_index, {BLOCK_OFFSET_WIDTH + 2{1'b0}}};
		mem_write_data.WVALID = state == STATE_FLUSH_DATA;
		mem_write_data.WID = 0;
		mem_write_data.WDATA = shift_rdata[0];
		mem_write_data.WLAST = last_flush_word;

		// Always ready to consume write response
		mem_write_response.BREADY = 1'b1;
	end

	always_comb begin
		mem_read_address.ARADDR = {r_tag, r_index, {BLOCK_OFFSET_WIDTH + 2{1'b0}}};
		mem_read_address.ARLEN = LINE_SIZE;
		mem_read_address.ARVALID = state == STATE_REFILL_REQUEST;
		mem_read_address.ARID = 4'd1;

		// Always ready to consume data
		mem_read_data.RREADY = 1'b1;
	end

	always_comb
	begin
		databank_we = '0;
		if (mem_read_data.RVALID)				// We are refilling data
			databank_we = databank_select;
		
		else if (state == STATE_VICTIM) begin
			databank_we[vt_counter] = 1'b1;
		end
		
		else if (hit & (in.mem_action == WRITE))	// We are storing a word
			databank_we[i_block_offset] = 1'b1;
	end

	always_comb
	begin
		if (state == STATE_READY)
		begin
			databank_wdata = in.data;
			databank_waddr = i_index;
			if (next_state == STATE_FLUSH_DATA)
				databank_raddr = i_index;
			else
				databank_raddr = i_index_next;
		end
		else if (state == STATE_VICTIM)
		begin
			databank_wdata = vt_rdata[vt_counter];
			databank_waddr = r_index;
			if (next_state == STATE_READY)
				databank_raddr = i_index_next;
			else
				databank_raddr = r_index;
		end
		else
		begin
			databank_wdata = mem_read_data.RDATA;
			databank_waddr = r_index;
			if (next_state == STATE_READY)
				databank_raddr = i_index_next;
			else
				databank_raddr = r_index;
		end
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
	end

	always_comb
	begin
		next_state = state;
		unique case (state)
			STATE_READY:
				if (miss)
					if (vt_hit && in.mem_action == READ && ~dirty_bits[i_index]) begin
						next_state = STATE_VICTIM;
					end
					else if (valid_bits[i_index] & dirty_bits[i_index])
						next_state = STATE_FLUSH_REQUEST;
					else
						next_state = STATE_REFILL_REQUEST;

			STATE_FLUSH_REQUEST:
				if (mem_write_address.AWREADY)
					next_state = STATE_FLUSH_DATA;

			STATE_FLUSH_DATA:
				if (last_flush_word && mem_write_data.WREADY)
					next_state = STATE_REFILL_REQUEST;

			STATE_REFILL_REQUEST:
				if (mem_read_address.ARREADY)
					next_state = STATE_REFILL_DATA;

			STATE_REFILL_DATA:
				if (last_refill_word)
					next_state = STATE_READY;
			
			STATE_VICTIM: // write data to databank from victim cache
				if (vt_counter == LINE_SIZE) next_state = STATE_READY;
				else next_state = STATE_VICTIM;
		endcase
	end

	always_ff @(posedge clk) begin
		if (~rst_n)
			pending_write_response <= 1'b0;
		else if (mem_write_address.AWVALID && mem_write_address.AWREADY)
			pending_write_response <= 1'b1;
		else if (mem_write_response.BVALID && mem_write_response.BREADY)
			pending_write_response <= 1'b0;
	end

	always_ff @(posedge clk)
	begin
		if (state == STATE_FLUSH_DATA && mem_write_data.WREADY)
			for (int i = 0; i < LINE_SIZE - 1; i++)
				shift_rdata[i] <= shift_rdata[i+1];

		if (state == STATE_FLUSH_REQUEST && next_state == STATE_FLUSH_DATA)
			for (int i = 0; i < LINE_SIZE; i++)
				shift_rdata[i] <= databank_rdata[i];
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
					end
					else if (in.mem_action == WRITE)
						dirty_bits[i_index] <= 1'b1;
				end

				STATE_FLUSH_DATA:
				begin
					if (mem_write_data.WREADY)
						databank_select <= {databank_select[LINE_SIZE - 2 : 0],
							databank_select[LINE_SIZE - 1]};
						
				end
				STATE_REFILL_DATA:
				begin
					if (mem_read_data.RVALID)
						databank_select <= {databank_select[LINE_SIZE - 2 : 0],
							databank_select[LINE_SIZE - 1]};

					if (last_refill_word || state == STATE_VICTIM)
					begin
						valid_bits[r_index] <= 1'b1;
						dirty_bits[r_index] <= 1'b0;
					end
				end
			endcase
		end
	end
endmodule


///Code below has been moved to victim_cache.sv and victim_cache_encoders.sv
/*
module victim_cache_d #(
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
	input logic [`ADDR_WIDTH - 1 :  BLOCK_OFFSET_WIDTH + 2] i_owaddr,
	input logic [`DATA_WIDTH - 1 : 0] i_owdata,
	input logic[BLOCK_OFFSET_WIDTH - 1 : 0] i_owoffset,
	input logic i_owe,
    output logic o_victim_hit,
    output logic[`DATA_WIDTH - 1 : 0] o_rdata[1<<BLOCK_OFFSET_WIDTH]
);

	localparam TAG_WIDTH = `ADDR_WIDTH - INDEX_WIDTH - BLOCK_OFFSET_WIDTH - 2;
	localparam LINE_SIZE = 1 << BLOCK_OFFSET_WIDTH;
	localparam DEPTH = 1 << INDEX_WIDTH;
	localparam CACHE_SIZE = 32;
    localparam CACHE_INDEX_SIZE = 5;
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
		else if (i_owe && o_victim_hit) begin
			data_table[output_index][i_owoffset] <= i_owdata;
		end
    end
	// Read from Victim Cache
	always_comb begin
		for (int i = 0; i < LINE_SIZE; i++) begin
         	o_rdata[i] = data_table[output_index][i];
		end
	end
	encoder_32bit_d output_encoder(
		.i_string(output_compared_results),
		.o_index(output_index),
		.o_valid(o_victim_hit)
	);
	encoder_32bit_d input_encoder(
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

module encoder_128bit_d (
	input logic[127:0] i_string,
	output logic[6:0] o_index,
	output logic o_valid
);
	logic o_valid1, o_valid2;
	logic[6:0] o_index1, o_index2;
	assign o_valid = o_valid1 ^ o_valid2;
	assign o_index = (o_valid1)? o_index1 : (o_index2 + 64);
	encoder_64bit_d encoder_64_1(
		.i_string(i_string[63:0]),
		.o_index(o_index1),
		.o_valid(o_valid1)
	);
	encoder_64bit_d encoder_64_2(
		.i_string(i_string[127:64]),
		.o_index(o_index2),
		.o_valid(o_valid2)
	);
endmodule

module encoder_64bit_d (
	input logic[63:0] i_string,
	output logic[5:0] o_index,
	output logic o_valid
);
	logic o_valid1, o_valid2;
	logic[5:0] o_index1, o_index2;
	assign o_valid = o_valid1 ^ o_valid2;
	assign o_index = (o_valid1)? o_index1 : (o_index2 + 32);
	encoder_32bit_d encoder_32_1(
		.i_string(i_string[31:0]),
		.o_index(o_index1),
		.o_valid(o_valid1)
	);
	encoder_32bit_d encoder_32_2(
		.i_string(i_string[63:32]),
		.o_index(o_index2),
		.o_valid(o_valid2)
	);
endmodule

module encoder_32bit_d (
	input logic[31:0] i_string,
	output logic[4:0] o_index,
	output logic o_valid
);
	logic o_valid1, o_valid2;
	logic[4:0] o_index1, o_index2;
	assign o_valid = o_valid1 ^ o_valid2;
	assign o_index = (o_valid1)? o_index1 : (o_index2 + 16);
	encoder_16bit_d encoder_16_1(
		.i_string(i_string[15:0]),
		.o_index(o_index1),
		.o_valid(o_valid1)
	);
	encoder_16bit_d encoder_16_2(
		.i_string(i_string[31:16]),
		.o_index(o_index2),
		.o_valid(o_valid2)
	);
endmodule

module encoder_16bit_d (
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