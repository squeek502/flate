pub const block = struct {
    pub const tokens = 1 << 14;
};

pub const match = struct {
    pub const base_length = 3; // smallest match length per the RFC section 3.2.5
    pub const min_length = 4; // min length used in this algorithm
    pub const max_length = 258;

    pub const min_distance = 1;
    pub const max_distance = 32768;
};

pub const window = struct { // TODO: consider renaming this into history
    pub const bits = 15;
    pub const size = 1 << bits;
    pub const mask = size - 1;
};

pub const hash = struct {
    pub const bits = 17;
    pub const size = 1 << bits;
    pub const mask = size - 1;
    pub const shift = 32 - bits;
};

// TODO: organize this

// Huffman Codes

// The largest offset code.
pub const offset_code_count = 30;
// Max number of frequencies used for a Huffman Code
// Possible lengths are codegenCodeCount (19), offset_code_count (30) and max_num_lit (286).
// The largest of these is max_num_lit.
pub const max_num_frequencies = max_num_lit;
// Maximum number of literals.
pub const max_num_lit = 286;

// Deflate

// Biggest block size for uncompressed block.
pub const max_store_block_size = 65535;
// The special code used to mark the end of a block.
pub const end_block_marker = 256;