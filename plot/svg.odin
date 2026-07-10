package plot

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// Writes the frame to svg/plot_<timestamp>.svg, using only the bare
// line/circle/polyline/polygon subset svg2hpgl.py understands. One <g> per
// distinct (color, weight), which svg2hpgl maps to a carousel pen. Hex rather
// than a colour name keeps that key stable through a vpype optimise pass.
export_svg :: proc() {
	os.make_directory("svg")
	now := time.now()
	year, month, day := time.date(now)
	hour, minute, second := time.clock_from_time(now)
	path := fmt.tprintf("svg/plot_%02d%02d%02d_%02d%02d%02d.svg",
		year % 100, int(month), day, hour, minute, second)

	Key :: struct {
		color: Color,
		weight: f32,
	}

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, `<svg xmlns="http://www.w3.org/2000/svg" width="%.0f" height="%.0f" viewBox="0 0 %.0f %.0f">`,
		canvas.width, canvas.height, canvas.width, canvas.height)

	styles := make([dynamic]Key, context.temp_allocator)
	for shape in canvas.shapes {
		key := Key{shape.color, shape.weight}
		if !slice.contains(styles[:], key) {
			append(&styles, key)
		}
	}

	for key in styles {
		fmt.sbprintfln(&b, `<g fill="none" stroke="#%02x%02x%02x" stroke-width="%.2f" stroke-linecap="round" stroke-linejoin="round">`,
			key.color.r, key.color.g, key.color.b, key.weight)
		for shape in canvas.shapes {
			if shape.color != key.color || shape.weight != key.weight {
				continue
			}
			fmt.sbprintf(&b, `<`)
			switch s in shape.geom {
			case Line:
				fmt.sbprintf(&b, `line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f"`, s.a.x, s.a.y, s.b.x, s.b.y)
			case Circle:
				fmt.sbprintf(&b, `circle cx="%.2f" cy="%.2f" r="%.2f"`, s.center.x, s.center.y, s.r)
			case Polyline:
				fmt.sbprintf(&b, `%s points="`, s.closed ? "polygon" : "polyline")
				for p, i in s.points {
					fmt.sbprintf(&b, "%s%.2f,%.2f", i > 0 ? " " : "", p.x, p.y)
				}
				fmt.sbprintf(&b, `"`)
			}
			fmt.sbprintfln(&b, `/>`)
		}
		fmt.sbprintfln(&b, "</g>")
	}

	fmt.sbprintfln(&b, "</svg>")

	if err := os.write_entire_file(path, strings.to_string(b)); err == nil {
		fmt.printfln("Exported %s (%d shapes)", path, len(canvas.shapes))
	} else {
		fmt.eprintfln("Failed to write %s: %v", path, err)
	}
}
