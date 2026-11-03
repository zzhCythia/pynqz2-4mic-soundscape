`timescale 1ns / 1ps

module audio_axis_4ch #(
    parameter integer FIFO_DEPTH = 4096
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        capture_en,

    input  wire        sample_valid,
    input  wire signed [23:0] sample_ch0,
    input  wire signed [23:0] sample_ch1,
    input  wire signed [23:0] sample_ch2,
    input  wire signed [23:0] sample_ch3,

    output wire [127:0] m_axis_tdata,
    output wire         m_axis_tvalid,
    output wire         m_axis_tlast,
    input  wire         m_axis_tready,
    output reg  [31:0] dropped_frames
);

    localparam integer PTR_WIDTH = $clog2(FIFO_DEPTH);
    (* ram_style = "block" *) reg [128:0] data_mem [0:FIFO_DEPTH-1];
    reg [PTR_WIDTH-1:0] wr_ptr;
    reg [PTR_WIDTH-1:0] rd_ptr;
    reg [PTR_WIDTH:0] fifo_count;
    reg [128:0] output_beat;
    reg output_valid;
    reg [10:0] frame_count;

    wire fifo_full = (fifo_count == FIFO_DEPTH);
    wire output_taken = output_valid && m_axis_tready;
    wire read_mem = capture_en && (fifo_count != 0) &&
                    (!output_valid || output_taken);
    wire write_mem = capture_en && sample_valid && !fifo_full;

    wire [127:0] packed_sample = {
        {8{sample_ch3[23]}}, sample_ch3,
        {8{sample_ch2[23]}}, sample_ch2,
        {8{sample_ch1[23]}}, sample_ch1,
        {8{sample_ch0[23]}}, sample_ch0
    };

    wire packed_last =
        (frame_count == 12'd1919);

    assign m_axis_tdata  = output_beat[127:0];
    assign m_axis_tvalid = capture_en && output_valid;
    assign m_axis_tlast  = output_beat[128];

    always @(posedge clk) begin
        if (write_mem)
            data_mem[wr_ptr] <= {packed_last, packed_sample};
        if (read_mem)
            output_beat <= data_mem[rd_ptr];
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr      <= {PTR_WIDTH{1'b0}};
            rd_ptr      <= {PTR_WIDTH{1'b0}};
            fifo_count  <= {(PTR_WIDTH+1){1'b0}};
            frame_count <= 12'd0;
            dropped_frames <= 32'd0;
            output_valid <= 1'b0;
        end else if (!capture_en) begin
            wr_ptr      <= {PTR_WIDTH{1'b0}};
            rd_ptr      <= {PTR_WIDTH{1'b0}};
            fifo_count  <= {(PTR_WIDTH+1){1'b0}};
            frame_count <= 12'd0;
            output_valid <= 1'b0;
        end else begin
            if (sample_valid && !write_mem && dropped_frames != 32'hffffffff)
                dropped_frames <= dropped_frames + 1'b1;

            if (write_mem) begin
                wr_ptr           <= wr_ptr + 1'b1;

                if (packed_last)
                    frame_count <= 12'd0;
                else
                    frame_count <= frame_count + 1'b1;
            end

            if (read_mem)
                rd_ptr <= rd_ptr + 1'b1;

            case ({write_mem, read_mem})
                2'b10: fifo_count <= fifo_count + 1'b1;
                2'b01: fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count;
            endcase

            if (read_mem)
                output_valid <= 1'b1;
            else if (output_taken)
                output_valid <= 1'b0;
        end
    end

endmodule
