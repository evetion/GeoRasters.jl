

function read(fn::AbstractString; masked=true)
    isfile(fn) || error("File not found.")
    # dataset = ArchGDAL.unsafe_read(fn)
    dataset = ArchGDAL.readraster(fn)
    am = get_affine_map(dataset.ds)
    wkt = ArchGDAL.getproj(dataset)

    # Not yet in type
    # meta = getmetadata(dataset)

    # nodata masking
    if masked
        mask = falses(size(dataset))
        for i = 1:size(dataset)[end]
            band = ArchGDAL.getband(dataset, i)
            maskflags = mask_flags(band)

            # All values are valid, skip masking
            if :GMF_ALL_VALID in maskflags
                @debug "No masking"
                continue
            # Mask is valid for all bands
            elseif :GMF_PER_DATASET in maskflags
                @debug "Mask for each band"
                maskband = ArchGDAL.getmaskband(band)
                m = ArchGDAL.read(maskband) .== 0
                mask[:,:,i] = m
            # Alpha layer
            elseif :GMF_ALPHA in maskflags
                @warn "Dataset has band $i with an Alpha band, which is unsupported for now."
                continue
            # Nodata values
            elseif :GMF_NODATA in maskflags
                @debug "Flag NODATA"
                nodata = get_nodata(band)
                mask[:, :, i] = dataset[:,:,i] .== nodata
            else
                @warn "Unknown/unsupported mask."
            end
        end

        if any(mask)
            dataset = Array{Union{Missing,eltype(dataset)}}(dataset)
            dataset[mask] .= missing
        end
    end
    GeoArray(dataset, am, wkt)
end

function write!(fn::AbstractString, ga::GeoArray, nodata = nothing, shortname = find_shortname(fn))
    options = String[]
    w, h, b = size(ga)
    dtype = eltype(ga)
    data = copy(ga.A)
    use_nodata = false

    # Set compression options for GeoTIFFs
    shortname == "GTiff" && (options = ["COMPRESS=DEFLATE","TILED=YES"])

    # Slice data and replace missing by nodata
    if isa(dtype, Union) && dtype.a == Missing
        dtype = dtype.b
        if dtype ∉ keys(ArchGDAL._GDALTYPE)
            dtype, data = cast_to_gdal(data)
        end
        nodata === nothing && (nodata = typemax(dtype))
        m = ismissing.(data)
        data[m] .= nodata
        data = Array{dtype}(data)
        use_nodata = true
    end

    if dtype ∉ keys(ArchGDAL._GDALTYPE)
        dtype, data = cast_to_gdal(data)
    end

    ArchGDAL.create(fn, driver = ArchGDAL.getdriver(shortname), width = w, height = h, nbands = b, dtype = dtype, options = options) do dataset
        for i = 1:b
            band = ArchGDAL.getband(dataset, i)
            ArchGDAL.write!(band, data[:,:,i])
            use_nodata && ArchGDAL.GDAL.gdalsetrasternodatavalue(band.ptr, nodata)
        end

        # Set geotransform and crs
        gt = affine_to_geotransform(ga.f)
        ArchGDAL.GDAL.gdalsetgeotransform(dataset.ptr, gt)
        ArchGDAL.GDAL.gdalsetprojection(dataset.ptr, GFT.val(ga.crs))

    end
    fn
end
