package sketch

import p "../../plot"
import "base:intrinsics"
import "core:math"
import "core:fmt"
import "core:math/rand"
import "core:math/linalg"
import "core:math/cmplx"
import "core:slice"

print_rounded :: proc(buf: []complex64) {
	fmt.print("[")
	for j in 0..<FFT_SIZE {
		c := buf[j]
		fmt.printf(" % 5.2f%+5.2fi", real(c), imag(c))
	}
	fmt.println("  ]")
}

make_mat :: proc(m, n: int) -> [][]complex64 {
	mat := make([][]complex64, m, allocator = context.temp_allocator)
	for i in 0..<m do mat[i] = make([]complex64, n, allocator = context.temp_allocator)
	return mat
}

print_mat :: proc(mat: [][]complex64) {
	for i in 0..<len(mat) {
		print_rounded(mat[i])
	}
}

round_cmplx :: proc(buf: []complex64) {
	for i in 0..<len(buf) {
		orig := buf[i]
		re := math.round(real(orig) / 0.001) * 0.001
		im := math.round(imag(orig) / 0.001) * 0.001
		buf[i] = complex(re, im)
	}
}
