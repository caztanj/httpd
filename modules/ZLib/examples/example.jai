main :: () {
    print("Testing ZLib compression and decompression...\n");

    original_text := "Hello, ZLib! This is a test of the ZLib compression library. Let's make this string long enough to actually compress well. Hello, ZLib! This is a test of the ZLib compression library. Let's make this string long enough to actually compress well. Hello, ZLib! This is a test of the ZLib compression library. Let's make this string long enough to actually compress well.";
    print("Original text length: % bytes\n", original_text.count);

    compressed_buffer: [1024] u8;

    dest_len:   ZLib.uLongf = cast(ZLib.uLongf) compressed_buffer.count;
    source_len: ZLib.uLong  = cast(ZLib.uLong)  original_text.count;

    rc := ZLib.compress(compressed_buffer.data, *dest_len, original_text.data, source_len);
    if rc != ZLib.Z_OK {
        print("Compression failed with code: %\n", rc);
        return;
    }

    print("Compressed size: % bytes\n", dest_len);

    decompressed_buffer: [1024] u8;
    decomp_len: ZLib.uLongf = cast(ZLib.uLongf) decompressed_buffer.count;

    rc = ZLib.uncompress(decompressed_buffer.data, *decomp_len, compressed_buffer.data, dest_len);
    if rc != ZLib.Z_OK {
        print("Decompression failed with code: %\n", rc);
        return;
    }

    print("Decompressed size: % bytes\n", decomp_len);

    result_string: string;
    result_string.data  = decompressed_buffer.data;
    result_string.count = cast(s64) decomp_len;

    if result_string == original_text {
        print("Success! Decompressed text matches the original.\n");
    } else {
        print("Mismatch! Decompressed text does not match the original.\n");
    }
}

#import "Basic";
#import "String";

ZLib :: #import,file "../module.jai";