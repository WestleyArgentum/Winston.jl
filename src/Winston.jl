require("Cairo")
require("IniFile")

module Winston

using Base
using Cairo
using Inifile

import Base.ref, Base.assign, Base.+, Base.-, Base.add, Base.isempty,
       Base.copy, Base.(*), Base.(/)

export PlotContainer
export Curve, FillAbove, FillBelow, FillBetween, Histogram, Image, Legend,
    LineX, LineY, PlotInset, PlotLabel, Points, Slope,
    SymmetricErrorBarsX, SymmetricErrorBarsY
export FramedArray, FramedPlot, Table
export file, setattr, style, svg

abstract HasAttr
abstract HasStyle <: HasAttr
abstract PlotComponent <: HasStyle
abstract PlotContainer <: HasAttr

typealias List Array{Any,1}
typealias PlotAttributes Associative # TODO: does Associative need {K,V}?

macro desc(x)
    :(println($(string(x))," = ",$(esc(x))))
end

# config ----------------------------------------------------------------------

type WinstonConfig
    inifile::IniFile

    function WinstonConfig()

        inifile = IniFile()

        # read global config
        local fn
        for dir in LOAD_PATH
            fn = joinpath(dir, "Winston.ini")
            if isfile(fn) break end
            fn = joinpath(dir, "Winston/src/Winston.ini")
            if isfile(fn) break end
        end
        read(inifile, fn)

        new(inifile)
    end
end

_winston_config = WinstonConfig()

function _atox(s::String)
    x = strip(s)
    if x == "nothing"
        return nothing
    elseif x == "true"
        return true
    elseif x == "false"
        return false
    elseif length(x) > 2 && lowercase(x[1:2]) == "0x"
        try
            h = parse_hex(x[3:end])
            return h
        end
    elseif x[1] == '{' && x[end] == '}'
        style = Dict()
        pairs = map(strip, split(x[2:end-1], ',', false))
        for pair in pairs
            kv = split(pair, ':', false)
            style[ strip(kv[1]) ] = _atox(strip(kv[2]))
        end
        return style
    elseif x[1] == '"' && x[end] == '"'
        return x[2:end-1]
    end
    try
        i = int(x)
        return i
    end
    try
        f = float(x)
        return f
    end
    return x
end

function config_value(section, option)
    global _winston_config
    strval = get(_winston_config.inifile, section, option, nothing)
    _atox(strval)
end

function config_options(sec::String)
    global _winston_config
    opts = Dict()
    if sec == "defaults"
        for (k,v) in _winston_config.inifile.defaults
            opts[k] = _atox(v)
        end
    elseif has_section(_winston_config.inifile, sec)
        for (k,v) in section(_winston_config.inifile, sec)
            opts[k] = _atox(v)
        end
    end
    opts
end

# utils -----------------------------------------------------------------------

function args2dict(args...)
    opts = Dict()
    if length(args) == 0
        return opts
    end
    iter = start(args)
    while !done(args, iter)
        arg, iter = next(args, iter)
        if typeof(arg) <: Associative
            for (k,v) in arg
                opts[k] = v
            end
        elseif typeof(arg) <: Tuple
            opts[arg[1]] = arg[2]
        else
            val, iter = next(args, iter)
            opts[arg] = val
        end
    end
    opts
end

function _draw_text(device, x::Real, y::Real, str::String, args...)
    save_state(device)
    for (key,val) in args2dict(args...)
        set(device, key, val)
    end
    text(device, x, y, str)
    restore_state(device)
end

function _first_not_none(args...)
    for arg in args
	if !is(arg,nothing)
	    return arg
        end
    end
    return nothing
end

include(find_in_path("Winston/src/boundingbox.jl"))

# relative size ---------------------------------------------------------------

function _size_relative(relsize, bbox::BoundingBox)
    w = width(bbox)
    h = height(bbox)
    yardstick = sqrt(8.) * w * h / (w + h)
    return (relsize/100.) * yardstick
end

function _fontsize_relative(relsize, bbox::BoundingBox, device_bbox::BoundingBox)
    devsize = _size_relative(relsize, bbox)
    fontsize_min = config_value("default", "fontsize_min")
    devsize_min = _size_relative(fontsize_min, device_bbox)
    return max(devsize, devsize_min)
end

# projections -------------------------------------------------------------

abstract Projection

type AffineTransformation
    t :: Array{Float64,1}
    m :: Array{Float64,2}
end

function AffineTransformation(x0, x1, y0, y1, dest::BoundingBox)
    sx = width(dest) / (x1 - x0)
    sy = height(dest) / (y1 - y0)
    p = lowerleft(dest)
    tx = p.x - sx * x0
    ty = p.y - sy * y0
    t = [tx, ty]
    m = diagm([sx, sy])
    AffineTransformation(t, m)
end

function project(self::AffineTransformation, x::Real, y::Real)
    #self.m*[x,y] + self.t
    u = self.t[1] + self.m[1,1] * x + self.m[1,2] * y
    v = self.t[2] + self.m[2,1] * x + self.m[2,2] * y
    u, v
end

project(proj::Projection, p::Point) = Point(project(proj, p.x, p.y)...)

function project(self::AffineTransformation, x::Vector, y::Vector)
    p = self.t[1] + self.m[1,1] * x + self.m[1,2] * y
    q = self.t[2] + self.m[2,1] * x + self.m[2,2] * y
    return p, q
end

project(self::AffineTransformation, x::AbstractArray, y::AbstractArray) =
    project(self, reshape(x,length(x)), reshape(y,length(y)))

function compose(self::AffineTransformation, other::AffineTransformation)
    self.t = call(other.t[1], other.t[2])
    self.m = self.m * other.m
end

type PlotGeometry <: Projection

    dest_bbox::BoundingBox
    xlog::Bool
    ylog::Bool
    aff::AffineTransformation
    xflipped::Bool
    yflipped::Bool

    function PlotGeometry(x0, x1, y0, y1, dest::BoundingBox, xlog, ylog)
        if xlog
            x0 = log10(x0)
            x1 = log10(x1)
        end
        if ylog
            y0 = log10(y0)
            y1 = log10(y1)
        end
        new(dest, xlog, ylog, AffineTransformation(x0,x1,y0,y1,dest), x0 > x1, y0 > y1)
    end

    PlotGeometry(x0, x1, y0, y1, dest) = PlotGeometry(x0, x1, y0, y1, dest, false, false)
end

function project(self::PlotGeometry, x, y)
    u, v = x, y
    if self.xlog
        u = log10(x)
    end
    if self.ylog
        v = log10(y)
    end
    return project(self.aff, u, v)
end

function geodesic(self::PlotGeometry, x, y)
    return [(x, y)]
end

# PlotContext -------------------------------------------------------------

type PlotContext
    draw
    dev_bbox::BoundingBox
    data_bbox::BoundingBox
    xlog
    ylog
    geom::Projection
    plot_geom::Projection

    function PlotContext(device::Renderer, dev::BoundingBox, data::BoundingBox, proj::Projection, xlog, ylog)
        new(
            device,
            dev,
            data,
            xlog,
            ylog,
            proj,
            PlotGeometry(0, 1, 0, 1, dev)
       )
    end

    PlotContext(device, dev, data, proj) = PlotContext(device, dev, data, proj, false, false)
end

function _kw_func_relative_fontsize(context::PlotContext, key, value)
    device_size = _fontsize_relative(value, context.dev_bbox, context.draw.bbox)
    set(context.draw, key, device_size)
end

function _kw_func_relative_size(context::PlotContext, key, value)
    device_size = _size_relative(value, context.dev_bbox)
    set(context.draw, key, device_size)
end

function _kw_func_relative_width(context::PlotContext, key, value)
    device_width = _size_relative(value/10., context.dev_bbox)
    set(context.draw, key, device_width)
end

function push_style(context::PlotContext, style)
    _kw_func = [
        "fontsize" => _kw_func_relative_fontsize,
        "linewidth" => _kw_func_relative_width,
        "symbolsize" => _kw_func_relative_size,
    ]
    save_state(context.draw)
    if !is(style,nothing)
        for (key, value) in style
            if has(_kw_func, key)
                method = _kw_func[key]
                method(context, key, value)
            else
                set(context.draw, key, value)
            end
        end
    end
end

function pop_style(context::PlotContext)
    restore_state(context.draw)
end

# =============================================================================
#
# RenderObjects
#
# =============================================================================

abstract RenderObject
typealias RenderStyle Dict{String,Union(Integer,FloatingPoint,String)}

function kw_init(self::RenderObject, args...)
    for (k,v) in kw_defaults(self)
        self.style[k] = v
    end
    for (key, value) in args2dict(args...)
        self.style[key] = value
    end
end

type LineObject <: RenderObject
    style::RenderStyle
    p
    q

    function LineObject(p, q, args...)
        self = new(RenderStyle(), p, q)
        kw_init(self, args...)
        self
    end
end

_kw_rename(::LineObject) = [
    "width"     => "linewidth",
    "type"      => "linetype",
]

function boundingbox(self::LineObject, context)
    bb = BoundingBox(self.p, self.q)
    bb
end

function draw(self::LineObject, context)
    line(context.draw, self.p, self.q)
end

type LabelsObject <: RenderObject
    style::RenderStyle
    points::AbstractVector
    labels::AbstractVector

    function LabelsObject(points, labels, args...)
        self = new(RenderStyle(), points, labels)
        kw_init(self, args...)
        self
    end
end

kw_defaults(::LabelsObject) = [
    "textangle"     => 0,
    "texthalign"    => "center",
    "textvalign"    => "center",
]

_kw_rename(::LabelsObject) = [
    "face"      => "fontface",
    "size"      => "fontsize",
    "angle"     => "textangle",
    "halign"    => "texthalign",
    "valign"    => "textvalign",
]

__halign_offset = [ "right"=>Vec2(-1,0), "center"=>Vec2(-.5,.5), "left"=>Vec2(0,1) ]
__valign_offset = [ "top"=>Vec2(-1,0), "center"=>Vec2(-.5,.5), "bottom"=>Vec2(0,1) ]

function boundingbox(self::LabelsObject, context)
    bb = BoundingBox()
    push_style(context, self.style)

    angle = get(context.draw, "textangle") * pi/180.
    halign = get(context.draw, "texthalign")
    valign = get(context.draw, "textvalign")

    height = textheight(context.draw, self.labels[1])
    ho = __halign_offset[halign]
    vo = __valign_offset[valign]

    for i = 1:length(self.labels)
        pos = self.points[i]
        width = textwidth(context.draw, self.labels[i])

        p = pos[1] + width * ho.x, pos[2] + height * vo.x
        q = pos[1] + width * ho.y, pos[2] + height * vo.y

        bb_label = BoundingBox(p, q)
        if angle != 0
            bb_label = rotate(bb_label, angle, pos)
        end
        bb += bb_label
    end

    pop_style(context)
    return bb
end

function draw(self::LabelsObject, context)
    for i in 1:length(self.labels)
        p = self.points[i]
        text(context.draw, p[1], p[2], self.labels[i])
    end
end

type CombObject <: RenderObject
    style::RenderStyle
    points
    dp

    function CombObject(points, dp, args...)
        self = new(RenderStyle())
        kw_init(self, args...)
        self.points = points
        self.dp = dp
        self
    end
end

function boundingbox(self::CombObject, context::PlotContext)
    return BoundingBox(self.points...)
end

function draw(self::CombObject, context::PlotContext)
    for p in self.points
        move(context.draw, p)
        linetorel(context.draw, self.dp)
    end
    stroke(context.draw)
end

type SymbolObject <: RenderObject
    style::RenderStyle
    pos::Point

    function SymbolObject(pos, args...)
        self = new(RenderStyle(), pos)
        kw_init(self, args...)
        self
    end
end

_kw_rename(::SymbolObject) = [
    "type" => "symboltype",
    "size" => "symbolsize",
]

function boundingbox(self::SymbolObject, context)
    push_style(context, self.style)
    symbolsize = get(context.draw, "symbolsize")
    pop_style(context)

    x = self.pos.x
    y = self.pos.y
    d = 0.5*symbolsize
    return BoundingBox(x-d, x+d, y-d, y+d)
end

function draw(self::SymbolObject, context)
    symbol(context.draw, self.pos.x, self.pos.y)
end

type SymbolsObject <: RenderObject
    style::RenderStyle
    x
    y

    function SymbolsObject(x, y, args...)
        self = new(RenderStyle())
        kw_init(self, args...)
        self.x = x
        self.y = y
        self
    end
end

_kw_rename(::SymbolsObject) = [
    "type" => "symboltype",
    "size" => "symbolsize",
]

function boundingbox(self::SymbolsObject, context::PlotContext)
    xmin = min(self.x)
    xmax = max(self.x)
    ymin = min(self.y)
    ymax = max(self.y)
    return BoundingBox((xmin,ymin), (xmax,ymax))
end

function draw(self::SymbolsObject, context::PlotContext)
    symbols(context.draw, self.x, self.y)
end

type TextObject <: RenderObject
    style::RenderStyle
    pos::Point
    str::String

    function TextObject(pos, str, args...)
        self = new(RenderStyle(), pos, str)
        kw_init(self, args...)
        self
    end
end

kw_defaults(::TextObject) = [
    "textangle"     => 0,
    "texthalign"    => "center",
    "textvalign"    => "center",
]

_kw_rename(::TextObject) = [
    "face"      => "fontface",
    "size"      => "fontsize",
    "angle"     => "textangle",
    "halign"    => "texthalign",
    "valign"    => "textvalign",
]

function boundingbox(self::TextObject, context::PlotContext)
    push_style(context, self.style)
    angle = get(context.draw, "textangle") * pi/180.
    halign = get(context.draw, "texthalign")
    valign = get(context.draw, "textvalign")
    width = textwidth(context.draw, self.str)
    height = textheight(context.draw, self.str)
    pop_style(context)

    hvec = width * __halign_offset[halign]
    vvec = height * __valign_offset[valign]

    p = self.pos.x + hvec.x, self.pos.y + vvec.x
    q = self.pos.x + hvec.y, self.pos.y + vvec.y

    bb = BoundingBox(p, q)
    bb = rotate(bb, angle, self.pos)
    return bb
end

function draw(self::TextObject, context::PlotContext)
    text(context.draw, self.pos.x, self.pos.y, self.str)
end

function LineTextObject(p::Point, q::Point, str, offset, args...)
    #kw_init(self, args...)
    #self.str = str

    midpoint = 0.5*(p + q)
    direction = q - p
    direction /= norm(direction)
    angle = atan2(direction.y, direction.x)
    direction = rotate(direction, pi/2)
    pos = midpoint + offset*direction

    kw = [ "textangle" => angle * 180./pi,
           "texthalign" => "center" ]
    if offset > 0
        kw["textvalign"] = "bottom"
    else
        kw["textvalign"] = "top"
    end
    TextObject(pos, str, args..., kw)
end

type PathObject <: RenderObject
    style::RenderStyle
    x::AbstractVector
    y::AbstractVector

    function PathObject(x, y, args...)
        self = new(RenderStyle())
        kw_init(self, args...)
        self.x = x
        self.y = y
        self
    end
end

_kw_rename(::PathObject) = [
    "width"     => "linewidth",
    "type"      => "linetype",
]

function boundingbox(self::PathObject, context)
    xmin = min(self.x)
    xmax = max(self.x)
    ymin = min(self.y)
    ymax = max(self.y)
    return BoundingBox((xmin,ymin), (xmax,ymax))
end

function draw(self::PathObject, context)
    curve(context.draw, self.x, self.y)
end

type PolygonObject <: RenderObject
    style::RenderStyle
    points::AbstractArray

    function PolygonObject(points, args...)
        self = new(RenderStyle())
        kw_init(self, args...)
        self.points = points
        self
    end
end

_kw_rename(::PolygonObject) = [
    "width"     => "linewidth",
    "type"      => "linetype",
]

function boundingbox(self::PolygonObject, context)
    return BoundingBox(self.points...)
end

function draw(self::PolygonObject, context)
    polygon(context.draw, self.points)
end

type ImageObject <: RenderObject
    style::RenderStyle
    img
    bbox

    function ImageObject(img, bbox, args...)
        self = new(RenderStyle(), img, bbox)
        kw_init(self, args...)
        self
    end
end

function boundingbox(self::ImageObject, context)
    return self.bbox
end

function draw(self::ImageObject, context)
    ll = lowerleft(self.bbox)
    w = width(self.bbox)
    h = height(self.bbox)
    image(context.draw, self.img, ll.x, ll.y, w, h)
end

# defaults

#function boundingbox(self::RenderObject, context)
#    return BoundingBox()
#end

function render(self::RenderObject, context)
    push_style(context, self.style)
    draw(self, context)
    pop_style(context)
end

# =============================================================================
#
# PlotObjects
#
# =============================================================================

# Legend ----------------------------------------------------------------------

type Legend <: PlotComponent
    attr::PlotAttributes
    x
    y
    components::Array{PlotComponent,1}

    function Legend(x, y, components, args...)
        self = new(Dict())
        conf_setattr(self)
        kw_init(self, args...)
        self.x = x
        self.y = y
        self.components = components
        self
    end
end

_kw_rename(::Legend) = [
    "face"      => "fontface",
    "size"      => "fontsize",
    "angle"     => "textangle",
    "halign"    => "texthalign",
    "valign"    => "textvalign",
]

function make(self::Legend, context::PlotContext)
    key_pos = project(context.plot_geom, self.x, self.y)
    key_width = _size_relative(getattr(self, "key_width"), context.dev_bbox)
    key_height = _size_relative(getattr(self, "key_height"), context.dev_bbox)
    key_hsep = _size_relative(getattr(self, "key_hsep"), context.dev_bbox)
    key_vsep = _size_relative(getattr(self, "key_vsep"), context.dev_bbox)

    halign = kw_get(self, "texthalign")
    if halign == "left"
        text_pos = Point(key_pos[1]+key_width/2+key_hsep, key_pos[2])
    else
        text_pos = Point(key_pos[1]-key_width/2-key_hsep, key_pos[2])
    end
    bbox = BoundingBox(key_pos[1]-key_width/2, key_pos[1]+key_width/2,
                       key_pos[2]-key_height/2, key_pos[2]+key_height/2)
    dp = Vec2(0., -(key_vsep + key_height))

    objs = {}
    for comp in self.components
        s = getattr(comp, "label", "")
        t = TextObject(text_pos, s, getattr(self,"style"))
        push(objs, t)
        push(objs, make_key(comp,bbox))
        text_pos = text_pos + dp
        bbox = shift(bbox, dp.x, dp.y)
    end
    objs
end

# ErrorBars --------------------------------------------------------------------

abstract ErrorBar <: PlotComponent

_kw_rename(::ErrorBar) = [
    "color" => "linecolor",
    "width" => "linewidth",
    "type" => "linetype",
]

type ErrorBarsX <: ErrorBar
    attr::PlotAttributes
    y
    lo
    hi

    function ErrorBarsX(y, lo, hi, args...)
        self = new(Dict())
        conf_setattr(self)
        kw_init(self, args...)
        self.y = y
        self.lo = lo
        self.hi = hi
        self
    end
end

function limits(self::ErrorBarsX)
    p = min(min(self.lo), min(self.hi)), min(self.y)
    q = max(max(self.lo), max(self.hi)), max(self.y)
    return BoundingBox(p, q)
end

function make(self::ErrorBarsX, context)
    l = _size_relative(getattr(self, "barsize"), context.dev_bbox)
    objs = {}
    for i = 1:numel(self.y)
        p = context.geom(self.lo[i], self.y[i])
        q = context.geom(self.hi[i], self.y[i])
        l0 = LineObject(p, q)
        l1 = LineObject((p[1],p[2]-l), (p[1],p[2]+l))
        l2 = LineObject((q[1],q[2]-l), (q[1],q[2]+l))
        push(objs, l0)
        push(objs, l1)
        push(objs, l2)
    end
    objs
end

type ErrorBarsY <: ErrorBar
    attr::PlotAttributes
    x
    lo
    hi

    function ErrorBarsY(x, lo, hi, args...)
        self = new(Dict())
        conf_setattr(self)
        kw_init(self, args...)
        self.x = x
        self.lo = lo
        self.hi = hi
        self
    end
end

function limits(self::ErrorBarsY)
    p = min(self.x), min(min(self.lo), min(self.hi))
    q = max(self.x), max(max(self.lo), max(self.hi))
    return BoundingBox(p, q)
end

function make(self::ErrorBarsY, context)
    objs = {}
    l = _size_relative(getattr(self, "barsize"), context.dev_bbox)
    for i = 1:numel(self.x)
        p = project(context.geom, self.x[i], self.lo[i])
        q = project(context.geom, self.x[i], self.hi[i])
        l0 = LineObject(p, q)
        l1 = LineObject((p[1]-l,p[2]), (p[1]+l,p[2]))
        l2 = LineObject((q[1]-l,q[2]), (q[1]+l,q[2]))
        push(objs, l0)
        push(objs, l1)
        push(objs, l2)
    end
    objs
end

function SymmetricErrorBarsX(x, y, err, args...)
    xlo = x - err
    xhi = x + err
    return ErrorBarsX(y, xlo, xhi, args...)
end

function SymmetricErrorBarsY(x, y, err, args...)
    ylo = y - err
    yhi = y + err
    return ErrorBarsY(x, ylo, yhi, args...)
end

# Inset -----------------------------------------------------------------------

abstract _Inset

function __init__(self, p, q, plot)
    self.plot_limits = BoundingBox(p, q)
    self.plot = plot
end

function render(self::_Inset, context::PlotContext)
    region = boundingbox(self, context)
    compose_interior(self.plot, context.draw, region)
end

type DataInset <: _Inset
    plot_limits
    plot::PlotContainer
    function DataInset(p, q, plot)
        self = new()
        self.plot_limits = BoundingBox(p, q)
        self.plot = plot
        self
    end
end

function boundingbox(self::DataInset, context::PlotContext)
    p = project(context.geom, lowerleft(self.plot_limits))
    q = project(context.geom, upperright(self.plot_limits))
    return BoundingBox(p, q)
end

function limits(self::DataInset)
    return copy(self.plot_limits)
end

type PlotInset <: _Inset
    plot_limits
    plot::PlotContainer
    function PlotInset(p, q, plot)
        self = new()
        self.plot_limits = BoundingBox(p, q)
        self.plot = plot
        self
    end
end

function boundingbox(self::PlotInset, context::PlotContext)
    p = project(context.plot_geom, lowerleft(self.plot_limits))
    q = project(context.plot_geom, upperright(self.plot_limits))
    return BoundingBox(p, q)
end

function limits(self::PlotInset)
    return BoundingBox()
end

# HalfAxis --------------------------------------------------------------------

function _magform(x)
    # Given x, returns (a,b), where x = a*10^b [a >= 1., b integral].
    if x == 0
        return 0., 0
    end
    a, b = modf(log10(abs(x)))
    a, b = 10^a, int(b)
    if a < 1.
        a, b = a * 10, b - 1
    end
    if x < 0.
        a = -a
    end
    return a, b
end

_format_ticklabel(x) = _format_ticklabel(x, 0.)
function _format_ticklabel(x, range)
    if x == 0
        return "0"
    end
    neg, digits, b = Base.Grisu.grisu(x, Base.Grisu.SHORTEST, int32(0))
    if length(digits) > 5
        neg, digits, b = Base.Grisu.grisu(x, Base.Grisu.PRECISION, int32(6))
        n = length(digits)
        while digits[n] == '0'
            n -= 1
        end
        digits = digits[1:n]
    end
    b -= 1
    if abs(b) > 4
        s = memio(1, false)
        if neg write(s, '-') end
        if digits != [0x31]
            write(s, char(digits[1]))
            if length(digits) > 1
                write(s, '.')
                for i = 2:length(digits)
                    write(s, char(digits[i]))
                end
            end
            write(s, L"\times ")
        end
        write(s, "10^{")
        write(s, dec(b))
        write(s, '}')
        return takebuf_string(s)
    end
    if range < 1e-6
        a, b = _magform(range)
        return "%.*f" % (abs(b),x)
    end
    s = sprint(showcompact, x)
    ends_with(s, ".0") ? s[1:end-2] : s
end

range(a::Integer, b::Integer) = (a <= b) ? (a:b) : (a:-1:b)

_ticklist_linear(lo, hi, sep) = _ticklist_linear(lo, hi, sep, 0.)
function _ticklist_linear(lo, hi, sep, origin)
    l = (lo - origin)/sep
    h = (hi - origin)/sep
    a, b = (l <= h) ? (iceil(l),ifloor(h)) : (ifloor(l),iceil(h))
    [ origin + i*sep for i in range(a,b) ]
end

function _ticks_default_linear(lim)
    a, b = _magform(abs(lim[2] - lim[1])/5.)
    if a < (1 + 2)/2.
        x = 1
    elseif a < (2 + 5)/2.
        x = 2
    elseif a < (5 + 10)/2.
        x = 5
    else
        x = 10
    end

    major_div = x * 10.0^b
    return _ticklist_linear(lim[1], lim[2], major_div)
end

function _ticks_default_log(lim)
    log_lim = log10(lim[1]), log10(lim[2])
    nlo = iceil(log10(lim[1]))
    nhi = ifloor(log10(lim[2]))
    nn = nhi - nlo +1

    if nn >= 10
        return [ 10.0^x for x=_ticks_default_linear(log_lim) ]
    elseif nn >= 2
        return [ 10.0^i for i=nlo:nhi ]
    else
        return _ticks_default_linear(lim)
    end
end

function _ticks_num_linear(lim, num)
    a = lim[1]
    b = (lim[2] - lim[1])/float(num-1)
    [ a + i*b for i=0:num-1 ]
end

function _ticks_num_log(lim, num)
    a = log10(lim[1])
    b = (log10(lim[2]) - a)/float(num - 1)
    [ 10.0^(a + i*b) for i=0:num-1 ]
end

_subticks_linear(lim, ticks) = _subticks_linear(lim, ticks, nothing)
function _subticks_linear(lim, ticks, num)
    major_div = (ticks[end] - ticks[1])/float(length(ticks) - 1)
    if is(num,nothing)
        _num = 4
        a, b = _magform(major_div)
        if 1. < a < (2 + 5)/2.
            _num = 3
        end
    else
        _num = num
    end
    minor_div = major_div/float(_num+1)
    return _ticklist_linear(lim[1], lim[2], minor_div, ticks[1])
end

_subticks_log(lim, ticks) = _subticks_log(lim, ticks, nothing)
function _subticks_log(lim, ticks, num)
    log_lim = log10(lim[1]), log10(lim[2])
    nlo = iceil(log10(lim[1]))
    nhi = ifloor(log10(lim[2]))
    nn = nhi - nlo +1

    if nn >= 10
        return [ 10.0^x for x in _subticks_linear(log_lim, map(log10,ticks), num) ]
    elseif nn >= 2
        minor_ticks = Float64[]
        for i in (nlo-1):nhi
            for j in 1:9
                z = j * 10.0^i
                if lim[1] <= z && z <= lim[2]
                    push(minor_ticks, z)
                end
            end
        end
        return minor_ticks
    else
        return _subticks_linear(lim, ticks, num)
    end
end

type _Group
    objs

    function _Group(objs)
        #self.objs = objs[:]
        new(copy(objs))
    end    
end

function boundingbox(self::_Group, context)
    bb = BoundingBox()
    for obj in self.objs
        bb += boundingbox(obj, context)
    end
    return bb
end

abstract HalfAxis <: PlotComponent

type HalfAxisX <: HalfAxis
    attr::Dict
    func_ticks_default
    func_ticks_num
    func_subticks_default
    func_subticks_num

    function HalfAxisX(args...)
        self = new(
            Dict(),
            (_ticks_default_linear, _ticks_default_log),
            (_ticks_num_linear, _ticks_num_log),
            (_subticks_linear, _subticks_log),
            (_subticks_linear, _subticks_log),
       )
        iniattr(self)
        kw_init(self, args...) 
        self
    end
end

_pos(self::HalfAxisX, context::PlotContext, a) = _pos(self, context, a, 0.)
function _pos(self::HalfAxisX, context::PlotContext, a, db)
    intcpt = _intercept(self, context)
    p = project(context.geom, a, intcpt)
    return p[1], p[2] + db
end

function _dpos(self::HalfAxisX, d)
    return 0., d
end

function _align(self::HalfAxisX)
    if getattr(self, "ticklabels_dir") < 0
        return "center", "top"
    else
        return "center", "bottom"
    end
end

function _intercept(self::HalfAxisX, context)
    if !is(getattr(self,"intercept"),nothing)
        return getattr(self, "intercept")
    end
    limits = context.data_bbox
    if (getattr(self, "ticklabels_dir") < 0) $ context.geom.yflipped
        return yrange(limits)[1]
    else
        return yrange(limits)[2]
    end
end

function _log(self::HalfAxisX, context)
    if is(getattr(self,"log"),nothing)
        return context.xlog
    end
    return getattr(self, "log")
end

function _side(self::HalfAxisX)
    if getattr(self, "ticklabels_dir") < 0
        return "bottom"
    else
        return "top"
    end
end

function _range(self::HalfAxisX, context)
    r = getattr(self, "range")
    if !is(r,nothing)
        a,b = r
        if is(a,nothing) || is(b,nothing)
            c,d = xrange(context.data_bbox)
            if is(a,nothing)
                a = c
            end
            if is(b,nothing)
                b = d
            end
            return a,b
        else
            return r
        end
    end
    return xrange(context.data_bbox)
end

function _make_grid(self::HalfAxisX, context, ticks)
    if isequal(ticks,nothing)
        return
    end
    objs = {}
    for tick in ticks
        push(objs, LineX(tick,getattr(self, "grid_style")))
    end
    objs
end

type HalfAxisY <: HalfAxis
    attr::Dict
    func_ticks_default
    func_ticks_num
    func_subticks_default
    func_subticks_num

    function HalfAxisY(args...)
        self = new(
            Dict(),
            (_ticks_default_linear, _ticks_default_log),
            (_ticks_num_linear, _ticks_num_log),
            (_subticks_linear, _subticks_log),
            (_subticks_linear, _subticks_log),
       )
        iniattr(self)
        kw_init(self, args...)
        self
    end
end

_pos(self::HalfAxisY, context, a) = _pos(self, context, a, 0.)
function _pos(self::HalfAxisY, context, a, db)
    p = project(context.geom, _intercept(self, context), a)
    return p[1] + db, p[2]
end

function _dpos(self::HalfAxisY, d)
    return d, 0.
end

function _align(self::HalfAxisY)
    if getattr(self, "ticklabels_dir") > 0
        return "left", "center"
    else
        return "right", "center"
    end
end

function _intercept(self::HalfAxisY, context)
    intercept = getattr(self, "intercept")
    if !is(intercept,nothing)
        return intercept
    end
    limits = context.data_bbox
    if (getattr(self, "ticklabels_dir") > 0) $ context.geom.xflipped
        return xrange(limits)[2]
    else
        return xrange(limits)[1]
    end
end

function _log(self::HalfAxisY, context)
    if is(getattr(self,"log"),nothing)
        return context.ylog
    end
    return getattr(self, "log")
end

function _side(self::HalfAxisY)
    if getattr(self, "ticklabels_dir") > 0
        return "right"
    else
        return "left"
    end
end

function _range(self::HalfAxisY, context)
    r = getattr(self, "range")
    if !is(r,nothing)
        a,b = r
        if is(a,nothing) || is(b,nothing)
            c,d = yrange(context.data_bbox)
            if is(a,nothing)
                a = c
            end
            if is(b,nothing)
                b = d
            end
            return a,b
        else
            return r
        end
    end
    return yrange(context.data_bbox)
end

function _make_grid(self::HalfAxisY, context, ticks)
    if isequal(ticks,nothing)
        return
    end
    objs = {}
    for tick in ticks
        push(objs, LineY(tick,getattr(self,"grid_style")))
    end
    objs
end

# defaults

_attr_map(::HalfAxis) = [
    "labeloffset"       => "label_offset",
    "major_ticklabels"  => "ticklabels",
    "major_ticks"       => "ticks",
    "minor_ticks"       => "subticks",
]

function _ticks(self::HalfAxis, context)
    logidx = _log(self, context) ? 2 : 1
    r = _range(self, context)
    ticks = getattr(self, "ticks")
    if isequal(ticks,nothing)
        return self.func_ticks_default[logidx](r)
    elseif typeof(ticks) <: Integer
        return self.func_ticks_num[logidx](r, ticks)
    else
        return ticks
    end
end

function _subticks(self::HalfAxis, context, ticks)
    logidx = _log(self, context) ? 2 : 1
    r = _range(self, context)
    subticks = getattr(self, "subticks")
    if isequal(subticks,nothing)
        return self.func_subticks_default[logidx](r, ticks)
    elseif typeof(subticks) <: Integer 
        return self.func_subticks_num[logidx](r, ticks, subticks)
    else
        return subticks
    end
end

function _ticklabels(self::HalfAxis, context, ticks)
    ticklabels = getattr(self, "ticklabels")
    if !isequal(ticklabels,nothing)
        return ticklabels
    end
    r = max(ticks) - min(ticks)
    [ _format_ticklabel(x,r) for x=ticks ]
end

function _make_ticklabels(self::HalfAxis, context, pos, labels)
    if isequal(labels,nothing) || length(labels) <= 0
        return
    end

    dir = getattr(self, "ticklabels_dir")
    offset = _size_relative(getattr(self, "ticklabels_offset"),
        context.dev_bbox)
    draw_ticks = getattr(self, "draw_ticks")
    if draw_ticks && getattr(self, "tickdir") > 0
        offset = offset + _size_relative(
            getattr(self, "ticks_size"), context.dev_bbox)
    end
    # XXX:why did square brackets stop working?
    labelpos = { _pos(self, context, pos[i], dir*offset) for i=1:length(labels) }

    halign, valign = _align(self)

    style = (String=>Any)[]
    style["texthalign"] = halign
    style["textvalign"] = valign
    for (k,v) in getattr(self, "ticklabels_style")
        style[k] = v
    end

    LabelsObject(labelpos, labels, style)
end

function _make_spine(self::HalfAxis, context)
    a, b = _range(self, context)
    p = _pos(self, context, a)
    q = _pos(self, context, b)
    LineObject(p, q, getattr(self, "spine_style"))
end

function _make_ticks(self::HalfAxis, context, ticks, size, style)
    if isequal(ticks,nothing) || length(ticks) <= 0
        return
    end

    dir = getattr(self, "tickdir") * getattr(self, "ticklabels_dir")
    ticklen = _dpos(self, dir * _size_relative(size, context.dev_bbox))
    # XXX:why did square brackets stop working?
    tickpos = { _pos(self, context, tick) for tick in ticks }

    CombObject(tickpos, ticklen, style)
end

function make(self::HalfAxis, context)
    if getattr(self, "draw_nothing")
        return []
    end

    ticks = _ticks(self, context)
    subticks = _subticks(self, context, ticks)
    ticklabels = _ticklabels(self, context, ticks)
    draw_ticks = getattr(self, "draw_ticks")
    draw_subticks = getattr(self, "draw_subticks")
    draw_ticklabels = getattr(self, "draw_ticklabels")

    implicit_draw_subticks = is(draw_subticks,nothing) && draw_ticks

    implicit_draw_ticklabels = is(draw_ticklabels,nothing) &&
        (!is(getattr(self, "range"),nothing) || !is(getattr(self, "ticklabels"),nothing))

    objs = {}
    if getattr(self, "draw_grid")
        objs = _make_grid(self, context, ticks)
    end

    if getattr(self, "draw_axis")
        if (!is(draw_subticks,nothing) && draw_subticks) || implicit_draw_subticks
            push(objs, _make_ticks(self, context, subticks,
                getattr(self, "subticks_size"),
                getattr(self, "subticks_style")))
        end

        if draw_ticks
            push(objs, _make_ticks(self, context, ticks,
                getattr(self, "ticks_size"),
                getattr(self, "ticks_style")))
        end

        if getattr(self, "draw_spine")
            push(objs, _make_spine(self, context))
        end
    end

    if (!is(draw_ticklabels,nothing) && draw_ticklabels) || implicit_draw_ticklabels
        push(objs, _make_ticklabels(self, context, ticks, ticklabels))
    end

    # has to be made last
    if hasattr(self, "label")
        if !is(getattr(self, "label"),nothing) # XXX:remove
            push(objs, BoxLabel(
                _Group(objs),
                getattr(self, "label"),
                _side(self),
                getattr(self, "label_offset"),
                getattr(self, "label_style")))
        end
    end
    objs
end

# PlotComposite ---------------------------------------------------------------

type PlotComposite <: HasStyle
    attr::Dict
    components::List
    dont_clip::Bool

    function PlotComposite(args...)
        self = new(Dict(), {}, false)
        kw_init(self, args...)
        self
    end
end

function add(self::PlotComposite, args...)
    for arg in args
        push(self.components, arg)
    end
end

function clear(self::PlotComposite)
    self.components = {}
end

function isempty(self::PlotComposite)
    return isempty(self.components)
end

function limits(self::PlotComposite)
    bb = BoundingBox()
    for obj in self.components
        bb += limits(obj)
    end
    return bb
end

function make(self::PlotComposite, context)
end

function boundingbox(self::PlotComposite, context)
    make(self, context)
    bb = BoundingBox()
    for obj in self.components
        bb += boundingbox(obj,context)
    end
    return bb
end

function render(self::PlotComposite, context)
    make(self, context)
    push_style(context, getattr(self,"style"))
    if !self.dont_clip
        xr = xrange(context.dev_bbox)
        yr = yrange(context.dev_bbox)
        set(context.draw, "cliprect", (xr[1], xr[2], yr[1], yr[2]))
    end
    for obj in self.components
        render(obj, context)
    end
    pop_style(context)
end

# -----------------------------------------------------------------------------

function _limits_axis(content_range, gutter, user_range, is_log)

    r0, r1 = 0, 1

    if !is(content_range,nothing)
        a, b = content_range
        if !is(a,nothing)
            r0 = a
        end
        if !is(b,nothing)
            r1 = b
        end
    end

    if !is(gutter,nothing)
        dx = 0.5 * gutter * (r1 - r0)
        a = r0 - dx
        if ! is_log || a > 0
            r0 = a
        end
        r1 = r1 + dx
    end

    if !is(user_range,nothing)
        a, b = user_range
        if !is(a,nothing)
            r0 = a
        end
        if !is(b,nothing)
            r1 = b
        end
    end

    if r0 == r1
        r0 = r0 - 1
        r1 = r1 + 1
    end

    return r0, r1
end

function _limits(content_bbox::BoundingBox, gutter, xlog, ylog, xr0, yr0)

    xr = _limits_axis(xrange(content_bbox), gutter, xr0, xlog)
    yr = _limits_axis(yrange(content_bbox), gutter, yr0, ylog)
    return BoundingBox((xr[1],yr[1]), (xr[2],yr[2]))
end

# FramedPlot ------------------------------------------------------------------

type _Alias
    objs
    _Alias(args...) = new(args)
end

#function project(self, args...) #,  args...)
#    for obj in self.objs
#        apply(obj, args, args...)
#    end
#end

#function getattr(self::_Alias, name)
#    objs = []
#    for obj in self.objs
#        objs.append(getattr(obj, name))
#    end
#    return apply(_Alias, objs)
#end

function setattr(self::_Alias, name, value)
    for obj in self.objs
        setattr(obj, name, value)
    end
end

#function __setitem__(self, key, value)
#    for obj in self.objs
#        obj[key] = value
#    end
#end

type FramedPlot <: PlotContainer
    attr::Associative # TODO: does Associative need {K,V}?
    content1::PlotComposite
    content2::PlotComposite
    x1::HalfAxis
    y1::HalfAxis
    x2::HalfAxis
    y2::HalfAxis
    frame::_Alias
    frame1::_Alias
    frame2::_Alias
    x::_Alias
    y::_Alias

    function FramedPlot(args...)
        x1 = HalfAxisX()
        setattr(x1, "ticklabels_dir", -1)
        y1 = HalfAxisY()
        setattr(y1, "ticklabels_dir", -1)
        x2 = HalfAxisX()
        setattr(x2, "draw_ticklabels", nothing)
        y2 = HalfAxisY()
        setattr(y2, "draw_ticklabels", nothing)
        self = new(
            Dict(),
            PlotComposite(),
            PlotComposite(),
            x1, y1, x2, y2,
            _Alias(x1, x2, y1, y2),
            _Alias(x1, y1),
            _Alias(x2, y2),
            _Alias(x1, x2),
            _Alias(y1, y2),
       )
        setattr(self.frame, "grid_style", ["linetype" => "dot"])
        setattr(self.frame, "tickdir", -1)
        setattr(self.frame1, "draw_grid", false)
        iniattr(self, args...)
        self
    end
end

_attr_map(fp::FramedPlot) = [
    "xlabel"    => (fp.x1, "label"),
    "ylabel"    => (fp.y1, "label"),
    "xlog"      => (fp.x1, "log"),
    "ylog"      => (fp.y1, "log"),
    "xrange"    => (fp.x1, "range"),
    "yrange"    => (fp.y1, "range"),
    "xtitle"    => (fp.x1, "label"),
    "ytitle"    => (fp.y1, "label"),
]

function getattr(self::FramedPlot, name)
    am = _attr_map(self)
    if has(am, name)
        a,b = get(am, name)
        #obj = self
        #for x in xs[:-1]
        #    obj = getattr(obj, x)
        #end
        return getattr(a, b)
    else
        return self.attr[name]
    end
end

function setattr(self::FramedPlot, name, value)
    am = _attr_map(self)
    if has(am, name)
        a,b = am[name]
        #obj = self
        #for x in xs[:-1]
        #    obj = getattr(obj, x)
        #end
        setattr(a, b, value)
    else
        self.attr[name] = value
    end
end

function isempty(self::FramedPlot)
    return isempty(self.content1) && isempty(self.content2)
end

function add(self::FramedPlot, args...)
    add(self.content1, args...)
end

function add2(self::FramedPlot, args...)
    add(self.content2, args...)
end

function _context1(self::FramedPlot, device::Renderer, region::BoundingBox)
    xlog = getattr(self.x1, "log")
    ylog = getattr(self.y1, "log")
    gutter = getattr(self, "gutter")
    l1 = limits(self.content1)
    xr = _limits_axis(xrange(l1), gutter, getattr(self.x1,"range"), xlog)
    yr = _limits_axis(yrange(l1), gutter, getattr(self.y1,"range"), ylog)
    lims = BoundingBox((xr[1],yr[1]), (xr[2],yr[2]))
    proj = PlotGeometry(xr..., yr..., region, xlog, ylog)
    return PlotContext(device, region, lims, proj, xlog, ylog)
end

function _context2(self::FramedPlot, device::Renderer, region::BoundingBox)
    xlog = _first_not_none(getattr(self.x2, "log"), getattr(self.x1, "log"))
    ylog = _first_not_none(getattr(self.y2, "log"), getattr(self.y1, "log"))
    gutter = getattr(self, "gutter")
    l2 = isempty(self.content2) ? limits(self.content1) : limits(self.content2)
    xr = _first_not_none(getattr(self.x2, "range"), getattr(self.x1, "range"))
    yr = _first_not_none(getattr(self.y2, "range"), getattr(self.y1, "range"))
    xr = _limits_axis(xrange(l2), gutter, xr, xlog)
    yr = _limits_axis(yrange(l2), gutter, yr, ylog)
    lims = BoundingBox((xr[1],yr[1]), (xr[2],yr[2]))
    proj = PlotGeometry(xr..., yr..., region, xlog, ylog)
    return PlotContext(device, region, lims, proj, xlog, ylog)
end

function exterior(self::FramedPlot, device::Renderer, region::BoundingBox)
    bb = copy(region)

    context1 = _context1(self, device, region)
    bb += boundingbox(self.x1, context1) +
          boundingbox(self.y1, context1)

    context2 = _context2(self, device, region)
    bb += boundingbox(self.x2, context2) +
          boundingbox(self.y2, context2)

    return bb
end

function compose_interior(self::FramedPlot, device::Renderer, region::BoundingBox)
    invoke(compose_interior, (PlotContainer,Renderer,BoundingBox), self, device, region)

    context1 = _context1(self, device, region)
    context2 = _context2(self, device, region)

    render(self.content1, context1)
    render(self.content2, context2)

    render(self.y2, context2)
    render(self.x2, context2)
    render(self.y1, context1)
    render(self.x1, context1)
end

# Table ------------------------------------------------------------------------

type _Grid
    nrows
    ncols
    origin
    step_x
    step_y
    cell_dimen

    function _Grid(nrows, ncols, bbox, cellpadding, cellspacing)
        self = new()
        self.nrows = nrows
        self.ncols = ncols

        w, h = width(bbox), height(bbox)
        cp = _size_relative(cellpadding, bbox)
        cs = _size_relative(cellspacing, bbox)

        self.origin = lowerleft(bbox) + Point(cp,cp)
        self.step_x = (w + cs)/ncols
        self.step_y = (h + cs)/nrows
        self.cell_dimen = (self.step_x - cs - 2*cp,
            self.step_y - cs - 2*cp)
        self
    end
end

function cellbb(self::_Grid, i::Int, j::Int)
    ii = self.nrows - i 
    p = self.origin + Point((j-1)*self.step_x, ii*self.step_y)
    return BoundingBox(p.x, p.x+self.cell_dimen[1], p.y, p.y + self.cell_dimen[2])
end

type Table <: PlotContainer
    attr::PlotAttributes
    rows::Int
    cols::Int
    content
    modified

    function Table(rows, cols, args...)
        self = new(Dict())
        conf_setattr(self, args...)
        self.rows = rows
        self.cols = cols
        self.content = cell(rows, cols)
        self.modified = false # XXX:fixme
        self
    end
end

function ref(self::Table, row::Int, col::Int)
    return self.content[row,col]
end

function assign(self::Table, obj::PlotContainer, row::Int, col::Int)
    self.content[row,col] = obj
    self.modified = true # XXX:fixme
end

isempty(self::Table) = !self.modified

function exterior(self::Table, device::Renderer, intbbox::BoundingBox)
    ext = copy(intbbox)

    if getattr(self, "align_interiors")
        g = _Grid(self.rows, self.cols, intbbox,
            getattr(self,"cellpadding"), getattr(self,"cellspacing"))

        for i = 1:self.rows
            for j = 1:self.cols
                obj = self.content[i,j]
                subregion = cellbb(g, i, j)
                ext += exterior(obj, device, subregion)
            end
        end
    end
    return ext
end

function compose_interior(self::Table, device::Renderer, intbbox::BoundingBox)
    invoke(compose_interior, (PlotContainer,Renderer,BoundingBox), self, device, intbbox)

    g = _Grid(self.rows, self.cols, intbbox,
        getattr(self,"cellpadding"), getattr(self,"cellspacing"))

    for i = 1:self.rows
        for j = 1:self.cols
            obj = self.content[i,j]
            subregion = cellbb(g, i, j)
            if getattr(self, "align_interiors")
                compose_interior(obj, device, subregion)
            else
                compose(obj, device, subregion)
            end
        end
    end
end

# Plot ------------------------------------------------------------------------

type Plot <: PlotContainer
    attr::PlotAttributes
    content

    function Plot(args...)
        self = new(Dict())
        conf_setattr(self, args...)
        self.content = PlotComposite()
        self
    end
end

function isempty(self::Plot)
    return isempty(self.content)
end

function add(self::Plot, args...)
    add(self.content, args...)
end

function limits(self::Plot)
    return _limits(limits(self.content), getattr(self,"gutter"),
        getattr(self,"xlog"), getattr(self,"ylog"),
        getattr(self,"xrange"), getattr(self,"yrange"))
end

compose_interior(self::Plot, device::Renderer, region::BoundingBox) =
    compose_interior(self, device, region, nothing)
function compose_interior(self::Plot, device, region, lmts)
    if is(lmts,nothing)
        lmts = limits(self)
    end
    xlog = getattr(self,"xlog")
    ylog = getattr(self,"ylog")
    proj = PlotGeometry(xrange(lmts)..., yrange(lmts)..., region, xlog, ylog)
    context = PlotContext(device, region, lmts, proj, xlog, ylog)
    render(self.content, context)
end

compose(self::Plot, device::Renderer, region::BoundingBox) =
    compose(self, device, region, nothing)
function compose(self::Plot, device, region, lmts)
    int_bbox = interior(self, device, region)
    compose_interior(self, device, int_bbox, lmts)
end

# FramedArray -----------------------------------------------------------------
#
# Quick and dirty, dirty hack...
#

function _frame_draw(obj, device, region, limits, labelticks)
    frame = Frame(labelticks)
    xlog = getattr(obj, "xlog")
    ylog = getattr(obj, "ylog")
    xr = xrange(limits)
    yr = yrange(limits)
    proj = PlotGeometry(xr..., yr..., region, xlog, ylog)
    context = PlotContext(device, region, limits, proj, xlog, ylog)
    render(frame, context)
end

_frame_bbox(obj, device, region, limits) =
    _frame_bbox(obj, device, region, limits, (0,1,1,0))
function _frame_bbox(obj, device, region, limits, labelticks)
    frame = Frame(labelticks)
    xlog = getattr(obj, "xlog")
    ylog = getattr(obj, "ylog")
    xr = xrange(limits)
    yr = yrange(limits)
    proj = PlotGeometry(xr..., yr..., region, xlog, ylog)
    context = PlotContext(device, region, limits, proj, xlog, ylog)
    return boundingbox(frame, context)
end

function _range_union(a, b)
    if is(a,nothing)
        return b
    end
    if is(b,nothing)
        return a
    end
    return min(a[1],b[1]), max(a[2],b[2])
end

type FramedArray <: PlotContainer
    attr::PlotAttributes
    nrows
    ncols
    content

    function FramedArray(nrows, ncols, args...)
        self = new(Dict())
        self.nrows = nrows
        self.ncols = ncols
        self.content = cell(nrows, ncols)
        for i in 1:nrows
            for j in 1:ncols
                self.content[i,j] = Plot()
            end
        end
        conf_setattr(self, args...)
        self
    end
end

function ref(self::FramedArray, row::Int, col::Int)
    return self.content[row,col]
end

# XXX:fixme
isempty(self::FramedArray) = false

function setattr(self::FramedArray, name, value)
    _attr_distribute = Set(
        "gutter",
        "xlog",
        "ylog",
        "xrange",
        "yrange",
   )
    if has(_attr_distribute, name)
        for i in 1:self.nrows, j=1:self.ncols
            setattr(self.content[i,j], name, value)
        end
    else
        self.attr[name] = value
    end
end

function _limits(self::FramedArray, i, j)
    if getattr(self, "uniform_limits")
        return _limits_uniform(self)
    else
        return _limits_nonuniform(self, i, j)
    end
end

function _limits_uniform(self)
    lmts = BoundingBox()
    for i in 1:self.nrows, j=1:self.ncols
        obj = self.content[i,j]
        lmts += limits(obj)
    end
    return lmts
end

function _limits_nonuniform(self::FramedArray, i, j)
    lx = nothing
    for k in 1:self.nrows
        l = limits(self.content[k,j])
        lx = _range_union(xrange(l), lx)
    end
    ly = nothing
    for k in 1:self.ncols
        l = limits(self.content[i,k])
        ly = _range_union(yrange(l), ly)
    end
    return BoundingBox((lx[1],ly[1]), (lx[2],ly[2]))
end

function _grid(self::FramedArray, interior)
    return _Grid(self.nrows, self.ncols, interior, 0., getattr(self, "cellspacing"))
end

function _frames_bbox(self::FramedArray, device, interior)
    bb = BoundingBox()
    g = _grid(self, interior)
    corners = [(1,1),(self.nrows,self.ncols)]

    for (i,j) in corners
        obj = self.content[i,j]
        subregion = cellbb(g, i, j)
        limits = _limits(self, i, j)
        axislabels = [0,0,0,0]
        if i == self.nrows
            axislabels[2] = 1
        end
        if j == 1
            axislabels[3] = 1
        end
        bb += _frame_bbox(obj, device, subregion, limits, axislabels)
    end

    return bb
end

function exterior(self::FramedArray, device::Renderer, int_bbox::BoundingBox)
    bb = _frames_bbox(self, device, int_bbox)

    labeloffset = _size_relative(getattr(self,"label_offset"), int_bbox)
    labelsize = _fontsize_relative(
        getattr(self,"label_size"), int_bbox, device.bbox)
    margin = labeloffset + labelsize

    if !is(getattr(self,"xlabel"),nothing)
        bb = deform(bb, 0, margin, 0, 0)
    end
    if !is(getattr(self,"ylabel"),nothing)
        bb = deform(bb, 0, 0, margin, 0)
    end

    return bb
end

function _frames_draw(self::FramedArray, device, interior)
    g = _grid(self, interior)

    for i in 1:self.nrows, j=1:self.ncols
        obj = self.content[i,j]
        subregion = cellbb(g, i, j)
        limits = _limits(self, i, j)
        axislabels = [0,0,0,0]
        if i == self.nrows
            axislabels[2] = 1
        end
        if j == 1
            axislabels[3] = 1
        end
        _frame_draw(obj, device, subregion, limits, axislabels)
    end
end

function _data_draw(self::FramedArray, device, interior)
    g = _grid(self, interior)

    for i in 1:self.nrows, j=1:self.ncols
        obj = self.content[i,j]
        subregion = cellbb(g, i, j)
        lmts = _limits(self, i, j)
        compose_interior(obj, device, subregion, lmts)
    end
end

function _labels_draw(self::FramedArray, device::Renderer, int_bbox::BoundingBox)
    bb = _frames_bbox(self, device, int_bbox)

    labeloffset = _size_relative(getattr(self,"label_offset"), int_bbox)
    labelsize = _fontsize_relative(
        getattr(self,"label_size"), int_bbox, device.bbox)

    save_state(device)
    set(device, "fontsize", labelsize)
    set(device, "texthalign", "center")
    if !is(getattr(self,"xlabel"),nothing)
        x = center(int_bbox).x
        y = ymin(bb) - labeloffset
        set(device, "textvalign", "top")
        text(device, x, y, getattr(self,"xlabel"))
    end
    if !is(getattr(self,"ylabel"),nothing)
        x = xmin(bb) - labeloffset
        y = center(int_bbox).y
        set(device, "textangle", 90.)
        set(device, "textvalign", "bottom")
        text(device, x, y, getattr(self,"ylabel"))
    end
    restore_state(device)
end

function add(self::FramedArray, args...)
    for i in 1:self.nrows, j=1:self.ncols
        obj = self.content[i,j]
        add(obj, args...)
    end
end

function compose_interior(self::FramedArray, device::Renderer, int_bbox::BoundingBox)
    invoke(compose_interior, (PlotContainer,Renderer,BoundingBox), self, device, int_bbox)
    _data_draw(self, device, int_bbox)
    _frames_draw(self, device, int_bbox)
    _labels_draw(self, device, int_bbox)
end

# Frame -----------------------------------------------------------------------

#type Frame
#    pc::PlotComposite
#    x1
#    x2
#    y1
#    y2
#
#    #function __init__(self, labelticks=(0,1,1,0), args...)
#        #apply(_PlotComposite.__init__, (self,), args...)
#    function Frame(labelticks, args...)
#        self = new()
#        pc = PlotComposite(args...)
#        pc.dont_clip = 1
#
#        self.x2 = _HalfAxisX()
#        self.x2.draw_ticklabels = labelticks[1]
#        self.x2.ticklabels_dir = 1
#
#        self.x1 = _HalfAxisX()
#        self.x1.draw_ticklabels = labelticks[2]
#        self.x1.ticklabels_dir = -1
#        
#        self.y1 = _HalfAxisY()
#        self.y1.draw_ticklabels = labelticks[3]
#        self.y1.ticklabels_dir = -1
#
#        self.y2 = _HalfAxisY()
#        self.y2.draw_ticklabels = labelticks[4]
#        self.y2.ticklabels_dir = 1
#        self
#    end
#end
#
#function make(self::Frame, context)
#    clear(self)
#    add(self, self.x1, self.x2, self.y1, self.y2)
#end

function Frame(labelticks, args...)
    #apply(_PlotComposite.__init__, (self,), args...)
    pc = PlotComposite(args...)
    setattr(pc, "dont_clip", true)

    x2 = HalfAxisX()
    setattr(x2, "draw_ticklabels", labelticks[1]==1)
    setattr(x2, "ticklabels_dir", 1)

    x1 = HalfAxisX()
    setattr(x1, "draw_ticklabels", labelticks[2]==1)
    setattr(x1, "ticklabels_dir", -1)
    
    y1 = HalfAxisY()
    setattr(y1, "draw_ticklabels", labelticks[3]==1)
    setattr(y1, "ticklabels_dir", -1)

    y2 = HalfAxisY()
    setattr(y2, "draw_ticklabels", labelticks[4]==1)
    setattr(y2, "ticklabels_dir", 1)

    add(pc, x1, x2, y1, y2)
    pc
end

# PlotContainer ---------------------------------------------------------------

function show(io::IO, self::PlotContainer)
    print(io, typeof(self))
end

function interior(self::PlotContainer, device::Renderer, exterior_bbox::BoundingBox)
    TOL = 0.005

    interior_bbox = copy(exterior_bbox)
    region_diagonal = diagonal(exterior_bbox)

    for i in 1:10
        bb = exterior(self, device, interior_bbox)

        dll = lowerleft(exterior_bbox) - lowerleft(bb)
        dur = upperright(exterior_bbox) - upperright(bb)

        sll = norm(dll) / region_diagonal
        sur = norm(dur) / region_diagonal

        if sll < TOL && sur < TOL
            # XXX:fixme
            ar = getattr(self, "aspect_ratio")
            if !is(ar,nothing)
                interior_bbox = make_aspect_ratio(interior_bbox, ar)
            end
            return interior_bbox
        end

        scale = diagonal(interior_bbox) / diagonal(bb)
        dll = scale * dll
        dur = scale * dur

        interior_bbox = BoundingBox(
            lowerleft(interior_bbox) + dll,
            upperright(interior_bbox) + dur)
    end

    println("warning: sub-optimal solution for plot")
    return interior_bbox
end

function exterior(self::PlotContainer, device::Renderer, interior::BoundingBox)
    return copy(interior)
end

function compose_interior(self::PlotContainer, device::Renderer, int_bbox::BoundingBox)
    if hasattr(self, "title")
        offset = _size_relative(getattr(self, "title_offset"), int_bbox)
        ext_bbox = exterior(self, device, int_bbox)
        x = center(int_bbox).x
        y = ymax(ext_bbox) + offset
        style = Dict()
        for (k,v) in getattr(self, "title_style")
            style[k] = v
        end
        style["fontsize"] = _fontsize_relative(
            getattr(self,"title_style")["fontsize"], int_bbox, device.bbox)
        style["texthalign"] = "center"
        style["textvalign"] = "bottom"
        _draw_text(device, x, y, getattr(self,"title"), style)
    end
end

function compose(self::PlotContainer, device::Renderer, region::BoundingBox)
    if isempty(self)
        error("empty container")
    end
    ext_bbox = copy(region)
    if hasattr(self, "title")
        offset = _size_relative(getattr(self,"title_offset"), ext_bbox)
        fontsize = _fontsize_relative(
            getattr(self,"title_style")["fontsize"], ext_bbox, device.bbox)
        ext_bbox = deform(ext_bbox, -offset-fontsize, 0, 0, 0)
    end
    int_bbox = interior(self, device, ext_bbox)
    compose_interior(self, device, int_bbox)
end

page_compose(self::PlotContainer, device::Renderer) =
    page_compose(self, device, true)
function page_compose(self::PlotContainer, device::Renderer, close_after)
    open(device)
    bb = BoundingBox(device.lowerleft, device.upperright)
    device.bbox = copy(bb)
    for (key,val) in config_options("defaults")
        set(device, key, val)
    end
    bb *= 1 - getattr(self, "page_margin")
    compose(self, device, bb)
    if close_after
        close(device)
    end
end

function x11(self::PlotContainer, args...)
    println("sorry, not implemented yet")
    return
    opts = args2dict(args...)
    width = has(opts,"width") ? opts["width"] : config_value("window","width")
    height = has(opts,"height") ? opts["height"] : config_value("window","height")
    reuse_window = isinteractive() && config_value("window","reuse")
    device = ScreenRenderer(reuse_window, width, height)
    page_compose(self, device)
end

function write_eps(self::PlotContainer, filename::String, width, height)
    device = EPSRenderer(filename, width, height)
    page_compose(self, device)
end

function write_pdf(self::PlotContainer, filename::String, width, height)
    device = PDFRenderer(filename, width, height)
    page_compose(self, device)
end

function write_multipage_pdf(plots::Vector, filename::String, width, height)
    device = PDFRenderer(filename, width, height)
    device.on_close = () -> nothing  ## otherwise, appends blank page
    for plt in plots
        page_compose(plt, device, false)
        show_page(device.ctx)
    end
    close(device)  # possible error on access without this
end

function write_png(self::PlotContainer, filename::String, width::Int, height::Int)
    device = PNGRenderer(filename, width, height)
    page_compose(self, device)
end

function file(self::PlotContainer, filename::String, args...)
    extn = filename[end-2:end]
    opts = args2dict(args...)
    if extn == "eps"
        width = has(opts,"width") ? opts["width"] : config_value("eps","width")
        height = has(opts,"height") ? opts["height"] : config_value("eps","height")
        write_eps(self, filename, width, height)
    elseif extn == "pdf"
        width = has(opts,"width") ? opts["width"] : config_value("pdf","width")
        height = has(opts,"height") ? opts["height"] : config_value("pdf","height")
        write_pdf(self, filename, width, height)
    elseif extn == "png"
        width = has(opts,"width") ? opts["width"] : config_value("window","width")
        height = has(opts,"height") ? opts["height"] : config_value("window","height")
        write_png(self, filename, width, height)
    else
        error("I can't export .$extn, sorry.")
    end
end

function file(plots::Vector, filename::String, args...)
    # plots::Vector{PlotContainer}
    extn = filename[end-2:end]
    opts = args2dict(args...)
    if extn == "pdf"
        width = has(opts,"width") ? opts["width"] : config_value("pdf","width")
        height = has(opts,"height") ? opts["height"] : config_value("pdf","height")
        write_multipage_pdf(plots, filename, width, height)
    else
        error("I can't export multiple pages to .$extn, sorry.")
    end
end

function svg(self::PlotContainer, args...)
    opts = args2dict(args...)
    width = has(opts,"width") ? opts["width"] : config_value("window","width")
    height = has(opts,"height") ? opts["height"] : config_value("window","height")
    stream = memio(0, false)
    device = SVGRenderer(stream, width, height)
    page_compose(self, device)
    s = takebuf_string(stream)
    a,b = search(s, "<svg")
    s[a:end]
end

#function multipage(plots, filename, args...)
#    file = _open_output(filename)
#    opt = copy(config_options("postscript"))
#    opt.update(args...)
#    device = PSRenderer(file, opt...)
#    for plot in plots
#        page_compose(plot, device)
#    end
#    delete(device)
#    _close_output(file)
#end

# LineComponent ---------------------------------------------------------------

abstract LineComponent <: PlotComponent

_kw_rename(::LineComponent) = [
    "color" => "linecolor",
    "width" => "linewidth",
    "type" => "linetype",
]

function make_key(self::LineComponent, bbox::BoundingBox)
    y = center(bbox).y
    p = xmin(bbox), y
    q = xmax(bbox), y
    return LineObject(p, q, getattr(self,"style"))
end

type Curve <: LineComponent
    attr::Dict
    x
    y

    function Curve(x, y, args...)
        attr = Dict() 
        self = new(attr, x, y)
        iniattr(self)
        kw_init(self, args2dict(args...)...)
        self
    end
end

function limits(self::Curve)
    p0 = min(self.x), min(self.y)
    p1 = max(self.x), max(self.y)
    return BoundingBox(p0, p1)
end

function make(self::Curve, context)
    segs = geodesic(context.geom, self.x, self.y)
    objs = {}
    for seg in segs
        x, y = project(context.geom, seg[1], seg[2])
        push(objs, PathObject(x, y))
    end
    objs
end

type Slope <: LineComponent
    attr::Dict
    slope::Real
    intercept

    function Slope(slope, intercept, args...)
        #LineComponent.__init__(self)
        self = new(Dict())
        conf_setattr(self)
        kw_init(self, args...)
        self.slope = slope
        self.intercept = intercept
        self
    end
end

function _x(self::Slope, y::Real)
    x0, y0 = self.intercept
    return x0 + float(y - y0) / self.slope
end

function _y(self::Slope, x::Real)
    x0, y0 = self.intercept
    return y0 + (x - x0) * self.slope
end

function make(self::Slope, context::PlotContext)
    xr = xrange(context.data_bbox)
    yr = yrange(context.data_bbox)
    if self.slope == 0
        l = { (xr[1], self.intercept[2]),
              (xr[2], self.intercept[2]) }
    else
        l = { (xr[1], _y(self, xr[1])),
              (xr[2], _y(self, xr[2])),
              (_x(self, yr[1]), yr[1]),
              (_x(self, yr[2]), yr[2]) }
    end
    #m = filter(context.data_bbox.contains, l)
    m = {}
    for el in l
        if contains(context.data_bbox, el[1], el[2])
            push(m, el)
        end
    end
    #sort!(m)
    objs = {}
    if length(m) > 1
        a = project(context.geom, m[1]...)
        b = project(context.geom, m[end]...)
        push(objs, LineObject(a, b))
    end
    objs
end

type Histogram <: LineComponent
    attr::PlotAttributes
    values
    x0
    binsize

    function Histogram(values, binsize, args...)
        self = new(Dict())
        conf_setattr(self)
        kw_init(self, args...)
        self.values = values
        self.x0 = 0 # XXX:fixme
        self.binsize = binsize
        self
    end
end

function limits(self::Histogram)
    nval = length(self.values)
    if getattr(self, "drop_to_zero")
        p = self.x0, min(0, min(self.values))
    else
        p = self.x0, min(self.values)
    end
    q = self.x0 + nval*self.binsize, max(self.values)
    return BoundingBox(p, q)
end

function make(self::Histogram, context::PlotContext)
    nval = length(self.values)
    drop_to_zero = getattr(self, "drop_to_zero")
    x = Float64[]
    y = Float64[]
    if drop_to_zero
        push(x, self.x0)
        push(y, 0)
    end
    for i in 0:nval-1
        xi = self.x0 + i * self.binsize
        yi = self.values[i+1]
        #x.extend([xi, xi + self.binsize])
        #y.extend([yi, yi])
        push(x, xi)
        push(x, xi + self.binsize)
        push(y, yi)
        push(y, yi)
    end
    if drop_to_zero
        push(x, self.x0 + nval*self.binsize)
        push(y, 0)
    end
    u, v = project(context.geom, x, y)
    [ PathObject(u, v) ]
end

type LineX <: LineComponent
    attr::PlotAttributes
    x

    function LineX(x, args...)
        self = new(Dict())
        conf_setattr(self)
        kw_init(self, args...)
        self.x = x
        self
    end
end

function limits(self::LineX)
    return BoundingBox(self.x, self.x, NaN, NaN)
end

function make(self::LineX, context::PlotContext)
    yr = yrange(context.data_bbox)
    a = project(context.geom, self.x, yr[1])
    b = project(context.geom, self.x, yr[2])
    [ LineObject(a, b) ]
end

type LineY <: LineComponent
    attr::PlotAttributes
    y

    function LineY(y, args...)
        self = new(Dict())
        conf_setattr(self)
        kw_init(self, args...)
        self.y = y
        self
    end
end

function limits(self::LineY)
    return BoundingBox(NaN, NaN, self.y, self.y)
end

function make(self::LineY, context::PlotContext)
    xr = xrange(context.data_bbox)
    a = project(context.geom, xr[1], self.y)
    b = project(context.geom, xr[2], self.y)
    [ LineObject(a, b) ]
end

type BoxLabel <: PlotComponent
    attr::PlotAttributes
    obj
    str::String
    side
    offset

    function BoxLabel(obj, str::String, side, offset, args...)
        @assert !is(str,nothing)
        self = new(Dict(), obj, str, side, offset)
        kw_init(self, args...)
        self
    end
end

_kw_rename(::BoxLabel) = [
    "face" => "fontface",
    "size" => "fontsize",
]

function make(self::BoxLabel, context)
    bb = boundingbox(self.obj, context)
    offset = _size_relative(self.offset, context.dev_bbox)
    if self.side == "top"
        p = upperleft(bb)
        q = upperright(bb)
    elseif self.side == "bottom"
        p = lowerleft(bb)
        q = lowerright(bb)
        offset = -offset
    elseif self.side == "left"
        p = lowerleft(bb)
        q = upperleft(bb)
    elseif self.side == "right"
        p = upperright(bb)
        q = lowerright(bb)
    end

    lt = LineTextObject(p, q, self.str, offset, getattr(self, "style"))
    [ lt ]
end

# LabelComponent --------------------------------------------------------------

abstract LabelComponent <: PlotComponent

_kw_rename(::LabelComponent) = [
    "face"      => "fontface",
    "size"      => "fontsize",
    "angle"     => "textangle",
    "halign"    => "texthalign",
    "valign"    => "textvalign",
]

#function limits(self::LabelComponent)
#    return BoundingBox()
#end

type DataLabel <: LabelComponent
    attr::PlotAttributes
    pos::Point
    str::String

    function DataLabel(x, y, str, args...)
        self = new(Dict())
        conf_setattr(self)
        kw_init(self, args...)
        self.pos = x, y
        self.str = str
        self
    end
end

function make(self::DataLabel, context)
    x,y = project(context.geom, self.pos)
    t = TextObject(Point(x,y), self.str, getattr(self, "style"))
    [ t ]
end

type PlotLabel <: LabelComponent
    attr::PlotAttributes
    pos::Point
    str::String

    function PlotLabel(x, y, str, args...)
        self = new(Dict())
        conf_setattr(self)
        kw_init(self, args...)
        self.pos = Point(x, y)
        self.str = str
        self
    end
end

function make(self::PlotLabel, context)
    pos = project(context.plot_geom, self.pos)
    t = TextObject(pos, self.str, getattr(self, "style"))
    [ t ]
end

# LabelsComponent ------------------------------------------------------------
#
#type Labels <: _PlotComponent
#
#    function __init__(self, x, y, labels, args...)
#        _PlotComponent.__init__(self)
#        self.conf_setattr("LabelsComponent")
#        self.conf_setattr("Labels")
#        kw_init(self, args...)
#        self.x = x
#        self.y = y
#        self.labels = labels
#    end
#end
#
#_kw_rename(::Labels) = [
#    "face"      => "fontface",
#    "size"      => "fontsize",
#    "angle"     => "textangle",
#    "halign"    => "texthalign",
#    "valign"    => "textvalign",
#]
#
#function limits(self::Labels)
#    p = min(self.x), min(self.y)
#    q = max(self.x), max(self.y)
#    return BoundingBox(p, q)
#end
#
#function make(self::Labels, context::PlotContext)
#    x, y = project(context.geom, self.x, self.y)
#    l = LabelsObject(zip(x,y), self.labels, self.kw_style)
#    add(self, l)
#end

# FillComponent -------------------------------------------------------------

abstract FillComponent <: PlotComponent

function make_key(self::FillComponent, bbox::BoundingBox)
    p = lowerleft(bbox)
    q = upperright(bbox)
    return BoxObject(p, q, getattr(self,"style"))
end

kw_defaults(::FillComponent) = [
    "color" => config_value("FillComponent","fillcolor"),
    "filltype" => config_value("FillComponent","filltype"),
]

type FillAbove <: FillComponent
    attr::PlotAttributes
    x
    y

    function FillAbove(x, y, args...)
        self = new(Dict())
        conf_setattr(self)
        kw_init(self, args...)
        self.x = x
        self.y = y
        self
    end
end

function limits(self::FillAbove)
    p = min(self.x), min(self.y)
    q = max(self.x), max(self.y)
    return BoundingBox(p, q)
end

function make(self::FillAbove, context)
    coords = map(context.geom, self.x, self.y)
    max_y = context.data_bbox.yrange()[1]
    coords.append(context.geom(self.x[-1], max_y))
    coords.append(context.geom(self.x[0], max_y))
    [ PolygonObject(coords) ]
end

type FillBelow <: FillComponent
    attr::PlotAttributes
    x
    y

    function FillBelow(x, y, args...)
        self = new(Dict())
        conf_setattr(self)
        kw_init(self, args...)
        self.x = x
        self.y = y
        self
    end
end

function limits(self::FillBelow)
    p = min(self.x), min(self.y)
    q = max(self.x), max(self.y)
    return BoundingBox(p, q)
end

function make(self::FillBelow, context)
    coords = map(context.geom, self.x, self.y)
    min_y = yrange(context.data_bbox)[0]
    push(coords, project(context.geom, self.x[-1], min_y))
    push(coords, project(context.geom, self.x[0], min_y))
    [ PolygonObject(coords) ]
end

type FillBetween <: FillComponent
    attr::PlotAttributes
    x1
    y1
    x2
    y2

    function FillBetween(x1, y1, x2, y2, args...)
        self = new(Dict())
        conf_setattr(self)
        kw_init(self, args...)
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
        self
    end
end

function limits(self::FillBetween)
    min_x = min(min(self.x1), min(self.x2))
    max_x = max(max(self.x1), max(self.x2))
    min_y = min(min(self.y1), min(self.y2))
    max_y = max(max(self.y1), max(self.y2))
    return BoundingBox((min_x,min_y), (max_x,max_y))
end

function make(self::FillBetween, context)
    x = [self.x1, reverse(self.x2)]
    y = [self.y1, reverse(self.y2)]
    coords = map((a,b) -> project(context.geom,a,b), x, y)
    [ PolygonObject(coords) ]
end

# ImageComponent -------------------------------------------------------------

abstract ImageComponent <: PlotComponent

kw_defaults(::ImageComponent) = Dict()

type Image <: ImageComponent
    attr::PlotAttributes
    img
    x
    y
    w
    h

    function Image(xrange, yrange, img, args...)
        x = min(xrange)
        y = min(yrange)
        w = abs(xrange[2] - xrange[1])
        h = abs(yrange[2] - yrange[1])
        self = new(Dict(), img, x, y, w, h)
        conf_setattr(self)
        kw_init(self, args...)
        self
    end
end

function limits(self::Image)
    p = self.x, self.y
    q = self.x+self.w, self.y+self.h
    return BoundingBox(p, q)
end

function make(self::Image, context)
    a = project(context.geom, self.x, self.y)
    b = project(context.geom, self.x+self.w, self.y+self.h)
    bbox = BoundingBox(a, b)
    [ ImageObject(self.img, bbox) ]
end

# SymbolDataComponent --------------------------------------------------------

abstract SymbolDataComponent <: PlotComponent

_kw_rename(::SymbolDataComponent) = [
    "type" => "symboltype",
    "size" => "symbolsize",
]

function make_key(self::SymbolDataComponent, bbox::BoundingBox)
    pos = center(bbox)
    return SymbolObject(pos, getattr(self,"style"))
end

type Points <: SymbolDataComponent
    attr::PlotAttributes
    x
    y

    function Points(x, y, args...)
        self = new(Dict())
        conf_setattr(self)
        kw_init(self, args...)
        self.x = x
        self.y = y
        self
    end
end

kw_defaults(::SymbolDataComponent) = [
    "symboltype" => config_value("Points","symboltype"),
    "symbolsize" => config_value("Points","symbolsize"),
]

function limits(self::SymbolDataComponent)
    p = min(self.x), min(self.y)
    q = max(self.x), max(self.y)
    return BoundingBox(p, q)
end

function make(self::SymbolDataComponent, context::PlotContext)
    x, y = project(context.geom, self.x, self.y)
    [ SymbolsObject(x, y) ]
end

function Point(x::Real, y::Real, args...)
    return Points([x], [y], args...)
end

type ColoredPoints <: SymbolDataComponent
    attr::PlotAttributes
    x
    y
    c

    function ColoredPoints(x, y, c, args...)
        self = new(Dict())
        conf_setattr(self)
        kw_init(self, args...)
        self.x = x
        self.y = y
        self.c = c
        self
    end
end

kw_defaults(::ColoredPoints) = [
    "symboltype" => config_value("Points","symboltype"),
    "symbolsize" => config_value("Points","symbolsize"),
]

function limits(self::ColoredPoints)
    p = min(self.x), min(self.y)
    q = max(self.x), max(self.y)
    return BoundingBox(p, q)
end

function make(self::ColoredPoints, context::PlotContext)
    x, y = project(context.geom, self.x, self.y)
    [ ColoredSymbolsObject(x, y, self.c) ]
end

function ColoredPoint(x::Real, y::Real, args...)
    return ColoredPoints([x], [y], args...)
end

# PlotComponent ---------------------------------------------------------------

function show(io::IO, self::PlotComponent)
    print(io,typeof(self),"()")
end

function limits(self::PlotComponent)
    return BoundingBox()
end

function make_key(self::PlotComponent, bbox::BoundingBox)
end

function boundingbox(self::PlotComponent, context::PlotContext)
    objs = make(self, context)
    bb = BoundingBox()
    for obj in objs
        x = boundingbox(obj, context)
        bb += x
    end
    return bb
end

function render(self::PlotComponent, context)
    objs = make(self, context)
    push_style(context, getattr(self,"style"))
    for obj in objs
        render(obj, context)
    end
    pop_style(context)
end

# HasAttr ---------------------------------------------------------------------

_attr_map(::HasAttr) = Dict()

function hasattr(self::HasAttr, name)
    key = get(_attr_map(self), name, name)
    return has(self.attr, key)
end

function getattr(self::HasAttr, name)
    key = get(_attr_map(self), name, name)
    return self.attr[key]
end

function getattr(self::HasAttr, name, notfound)
    key = get(_attr_map(self), name, name)
    return has(self.attr,key) ? self.attr[key] : notfound
end

function setattr(self::HasAttr, name, value)
    key = get(_attr_map(self), name, name)
    self.attr[key] = value
end

function iniattr(self::HasAttr, args...)
    types = {typeof(self)}
    while super(types[end]) != Any
        push(types, super(types[end]))
    end
    for t in reverse(types)
        name = string(t)
        for (k,v) in config_options(name)
            setattr(self, k, v)
        end
    end
    for (k,v) in args2dict(args...)
        setattr(self, k, v)
    end
end

const conf_setattr = iniattr

# HasStyle ---------------------------------------------------------------

kw_defaults(x) = Dict()
_kw_rename(x) = (String=>String)[]

function kw_init(self::HasStyle, args...)
    # jeez, what a mess...
    sty = Dict()
    for (k,v) in kw_defaults(self)
        sty[k] = v
    end
    if hasattr(self, "kw_defaults")
        for (k,v) in getattr(self, "kw_defaults")
            sty[k] = v
        end
    end
    setattr(self, "style", sty)
    for (key, value) in args2dict(args...)
        kw_set(self, key, value)
    end
end

function kw_set(self::HasStyle, name, value)
    #if !hasattr(self, "style")
    #    kw_init(self)
    #end
    key = get(_kw_rename(self), name, name)
    getattr(self, "style")[key] = value
end

function style(self::HasStyle, args...)
    for (key,val) in args2dict(args...)
        kw_set(self, key, val)
    end
end

kw_get(self::HasStyle, key) = kw_get(self, key, nothing)
function kw_get(self::HasStyle, key, notfound)
    return get(getattr(self,"style"), key, notfound)
end

end # module
