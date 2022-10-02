/*
Value history table for value prediction
*/

module lvpt
(	
	input clk,
	pc_ifc.out o_pc,
	load_pc_ifc.in load_pc_in, 
	load_pc_ifc.out load_pc_out,
	alu_pass_through_ifc.in alu_in,
	alu_pass_through_ifc.out alu_out,
	d_cache_pass_through_ifc.in d_in,
	d_cache_input_ifc.out d_out,
	value_table_ifc.in val_in,
	value_table_ifc.out val_out

);
localparam INDEX_WIDTH = 8;
localparam TAG_WIDTH = `ADDR_WIDTH - INDEX_WIDTH;
localparam CONFIDENCE = 2;
localparam UNIT = 1;

logic [TAG_WIDTH+UNIT+CONFIDENCE-1:0] conf_table [256];
logic [`DATA_WIDTH - 1 : 0] lvpt [1024];

logic [`DATA_WIDTH - 1 : 0] r_predicted_data;
logic r_predict;
logic r_recover_predict;

assign val_out.predicted = r_predict;	
assign val_out.pred_data = r_predicted_data;
assign val_out.recover_pred = r_recover_predict;
assign val_out.recover_pred = d_out.data != r_predicted_data;

logic [INDEX_WIDTH-1:0] ex_index;
logic [TAG_WIDTH-1:0] ex_tag;
logic [UNIT-1:0] ex_UNIT;
logic [CONFIDENCE-1:0] ex_confindence;
assign ex_index = o_pc.pc[INDEX_WIDTH-1:0];
assign {ex_tag,ex_UNIT,ex_confindence} = conf_table[ex_index];

logic [INDEX_WIDTH-1:0] mem_index;
logic [TAG_WIDTH-1:0] mem_tag;
logic [UNIT-1:0] mem_UNIT;
logic [CONFIDENCE-1:0] mem_confidence;
assign mem_index = alu_out.recovery_target[INDEX_WIDTH-1:0];
assign {mem_tag,mem_UNIT,mem_confidence} = conf_table[mem_index];

logic [CONFIDENCE-1:0] temp_mem_conf;

always_comb
begin
	for (int i = 0; i < (2**INDEX_WIDTH); i++)
	begin
		lvpt[i] = 0;
		conf_table[i] = 0;
	end
end

always_comb
begin
	if (d_out.data == lvpt[mem_index])
		if (mem_confidence + 1 != 0) temp_mem_conf = mem_confidence + 1;
		else temp_mem_conf = mem_confidence;
	else temp_mem_conf = mem_confidence - 1;
end
	
always_ff @(posedge clk)
begin
	r_recover_predict <= 1'b0;
	r_predict <= 1'b0;
	if (load_pc_in.we)
	begin
		// Indexing into Confidence Table
		if (ex_tag == o_pc.pc[INDEX_WIDTH +: TAG_WIDTH])
			// Confidence Threshold
			if (ex_confindence[CONFIDENCE-1] == 1)
			begin
				r_predicted_data <= lvpt[ex_index];
				r_predict <= 1'b1;
			end
	end
	if (d_in.is_mem_access && d_in.uses_rw && val_in.val_predicted)
	begin
		// Prediction check
		if (mem_tag == alu_out.recovery_target[INDEX_WIDTH +: TAG_WIDTH]) conf_table[mem_index][CONFIDENCE-1:0] <= temp_mem_conf;
			if (d_out.data != lvpt[mem_index])
				if (mem_confidence + 1 != 0) conf_table[mem_index][CONFIDENCE-1:0] <= mem_confidence + 1;
				else conf_table[mem_index][CONFIDENCE-1:0] <= mem_confidence;
			else
			//Confidence Table
			begin
				r_recover_predict <= 1;
				conf_table[mem_index][CONFIDENCE-1:0] <= mem_confidence - 1;
				if (temp_mem_conf[CONFIDENCE-1] == 0) lvpt[mem_index] = d_out.data;
			end
	end
end

endmodule 