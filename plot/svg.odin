package plot

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// Writes the current frame's shapes to svg/plot_<timestamp>.svg. Emits only
// bare line/circle/polyline/polygon elements with coordinates already in
// canvas space -- the subset svg2hpgl.py in ../hpgl_plot understands.
// Shapes are grouped into one <g> per pen, tagged data-pen="n", so a converter
// can plot pens separately without losing registration (single shared canvas).
export_svg :: proc(c: ^Canvas) {
	os.make_directory("svg")
	now := time.now()
	year, month, day := time.date(now)
	hour, minute, second := time.clock_from_time(now)
	path := fmt.tprintf("svg/plot_%02d%02d%02d_%02d%02d%02d.svg",
		year % 100, int(month), day, hour, minute, second)

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, `<svg xmlns="http://www.w3.org/2000/svg" width="%.0f" height="%.0f" viewBox="0 0 %.0f %.0f">`,
		c.width, c.height, c.width, c.height)
	for pen_n in 1 ..= 8 {
		opened := false
		for shape in c.shapes {
			if shape.pen != pen_n {
				continue
			}
			if !opened {
				fmt.sbprintfln(&b, `<g data-pen="%d" fill="none" stroke="%s" stroke-linecap="round" stroke-linejoin="round">`,
					pen_n, PEN_SVG_COLORS[pen_n])
				opened = true
			}
			fmt.sbprintf(&b, `<`)
			switch s in shape.geom {
			case Line:
				fmt.sbprintf(&b, `line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f"`, s.a.x, s.a.y, s.b.x, s.b.y)
			case Circle:
				fmt.sbprintf(&b, `circle cx="%.2f" cy="%.2f" r="%.2f"`, s.center.x, s.center.y, s.r)
			case Polyline:
				fmt.sbprintf(&b, s.closed ? `polygon points="` : `polyline points="`)
				for p, i in s.points {
					fmt.sbprintf(&b, "%s%.2f,%.2f", i > 0 ? " " : "", p.x, p.y)
				}
				fmt.sbprintf(&b, `"`)
			}
			fmt.sbprintfln(&b, ` stroke-width="%.2f"/>`, shape.weight)
		}
		if opened {
			fmt.sbprintfln(&b, "</g>")
		}
	}

	fmt.sbprintfln(&b, "</svg>")

	if err := os.write_entire_file(path, strings.to_string(b)); err == nil {
		fmt.printfln("Exported %s (%d shapes)", path, len(c.shapes))
	} else {
		fmt.eprintfln("Failed to write %s: %v", path, err)
	}
}
