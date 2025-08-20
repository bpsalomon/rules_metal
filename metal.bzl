""" Rules for organizing and compiling Metal. """

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@bazel_skylib//lib:paths.bzl", "paths")
load("@build_bazel_apple_support//lib:apple_support.bzl", "apple_support")

MetalFilesInfo = provider(
    "Collects Metal AIR files and headers",
    fields = ["transitive_airs", "transitive_headers", "transitive_header_paths"],
)

def get_transitive_airs(airs, deps):
    """Obtain the source files for a target and its transitive dependencies.

    Args:
      srcs: a list of source files
      deps: a list of targets that are direct dependencies
    Returns:
      a collection of the transitive sources
    """
    return depset(
        airs,
        transitive = [dep[MetalFilesInfo].transitive_airs for dep in deps],
    )

def get_transitive_hdrs(hdrs, deps):
    """Obtain the header files for a target and its transitive dependencies.

    Args:
      hdrs: a list of header files
      deps: a list of targets that are direct dependencies
    Returns:
      a collection of the transitive headers
    """
    return depset(
        hdrs,
        transitive = [dep[MetalFilesInfo].transitive_headers for dep in deps],
    )

def get_transitive_hdr_paths(paths, deps):
    """Obtain the header include paths for a target and its transitive dependencies.

    Args:
      paths: a list of header file include paths
      deps: a list of targets that are direct dependencies
    Returns:
      a collection of the transitive header include paths
    """
    return depset(
        paths,
        transitive = [dep[MetalFilesInfo].transitive_header_paths for dep in deps],
    )

def _process_hdrs(ctx, hdrs, include_prefix, strip_include_prefix):
    if strip_include_prefix == "" and include_prefix == "":
        return paths.dirname(ctx.build_file_path), hdrs
    if paths.is_absolute(strip_include_prefix):
        fail("should be relative", attr = "strip_include_prefix")
    if paths.is_absolute(include_prefix):
        fail("should be relative", attr = "include_prefix")
    virtual_hdr_prefix = paths.join("_virtual_hdrs", ctx.label.name)
    virtual_hdr_path = paths.join(
        ctx.genfiles_dir.path,
        paths.dirname(ctx.build_file_path),
        virtual_hdr_prefix,
    )
    virtual_hdr_prefix = paths.join(virtual_hdr_prefix, include_prefix)

    full_strip_prefix = paths.normalize(paths.join(
        ctx.label.package,
        ctx.attr.strip_include_prefix,
    )) + "/"

    virtual_hdrs = []
    for hdr in hdrs:
        if full_strip_prefix != "" and not hdr.short_path.startswith(full_strip_prefix):
            fail("hdr '%s' is not under the specified strip prefix '%s'" %
                 (hdr, strip_include_prefix))
        virtual_hdr_name = paths.join(
            virtual_hdr_prefix,
            hdr.short_path.removeprefix(full_strip_prefix),
        )
        virtual_hdr = ctx.actions.declare_file(virtual_hdr_name)
        ctx.actions.symlink(
            output = virtual_hdr,
            target_file = hdr,
            progress_message = "Symlinking virtual hdr sources for %{label}",
        )
        virtual_hdrs.append(virtual_hdr)

    return virtual_hdr_path, virtual_hdrs

def _is_debug(ctx):
    return ctx.var["COMPILATION_MODE"] == "dbg"

def _get_os_version_flag(ctx):
    if ctx.fragments.apple.apple_platform_type == "ios":
        if ctx.fragments.apple.ios_minimum_os_flag:
            return "-mios-version-min={}".format(ctx.fragments.apple.ios_minimum_os_flag)
        print(ctx.fragments.apple.ios_minimum_os_flag)
    elif ctx.fragments.apple.apple_platform_type == "macos":
        if ctx.fragments.apple.macos_minimum_os_flag:
            return "-mmacos-version-min={}".format(ctx.fragments.apple.macos_minimum_os_flag)
    return None

def _compile_metals(metals, hdrs, hdr_paths, ctx):
    _get_os_version_flag(ctx)
    air_files = []

    version_flag = _get_os_version_flag(ctx)

    for src_metal in metals:
        air_file = ctx.actions.declare_file(paths.replace_extension(src_metal.basename, ".air"))
        air_files.append(air_file)
        input_files = [src_metal] + [src_hdr for src_hdr in hdrs]

        args = ctx.actions.args()
        args.add("metal")
        args.add("-c")
        if version_flag:
            args.add(version_flag)

        if _is_debug(ctx):
            args.add("-frecord-sources")
            args.add("-g")

        args.add("-o", air_file)
        for path in hdr_paths.to_list():
            args.add("-I", path)
        args.add(src_metal.path)

        args.add_all(ctx.attr.copts)

        apple_support.run(
            actions = ctx.actions,
            xcode_config = ctx.attr._xcode_config[apple_common.XcodeVersionConfig],
            apple_fragment = ctx.fragments.apple,
            inputs = input_files,
            outputs = [air_file],
            executable = "/usr/bin/xcrun",
            arguments = [args],
            mnemonic = "MetalCompile",
        )
    return air_files

def _metal_library_impl(ctx):
    hdr_path, hdrs = _process_hdrs(
        ctx,
        ctx.files.hdrs,
        ctx.attr.include_prefix,
        ctx.attr.strip_include_prefix,
    )
    trans_hdrs = get_transitive_hdrs(hdrs, ctx.attr.deps)
    trans_hdr_paths = get_transitive_hdr_paths([hdr_path], ctx.attr.deps)

    srcs_list = ctx.files.srcs + trans_hdrs.to_list()

    srcs_metal_list = [x for x in srcs_list if x.extension == "metal"]

    srcs_hdrs_list = [x for x in srcs_list if x.extension == "h" or x.extension == "hpp"]

    air_files = _compile_metals(srcs_metal_list, srcs_hdrs_list, trans_hdr_paths, ctx)

    trans_airs = get_transitive_airs(air_files, ctx.attr.deps)

    return [MetalFilesInfo(
        transitive_airs = trans_airs,
        transitive_headers = trans_hdrs,
        transitive_header_paths = trans_hdr_paths,
    )]

metal_library = rule(
    implementation = _metal_library_impl,
    fragments = ["apple"],
    attrs = dicts.add(
        apple_support.action_required_attrs(),
        {
            "srcs": attr.label_list(allow_files = [".metal", ".h", ".hpp"]),
            "hdrs": attr.label_list(allow_files = [".h", ".hpp"]),
            "deps": attr.label_list(),
            "copts": attr.string_list(),
            "include_prefix": attr.string(),
            "strip_include_prefix": attr.string(),
        },
    ),
)

def _metal_binary_impl(ctx):
    metallib_file = ctx.outputs.out
    if metallib_file == None:
        metallib_file = ctx.actions.declare_file(ctx.label.name + ".metallib")

    trans_hdrs = get_transitive_hdrs([], ctx.attr.deps)
    trans_hdr_paths = get_transitive_hdr_paths([], ctx.attr.deps)
    srcs_list = ctx.files.srcs + trans_hdrs.to_list()

    srcs_metal_list = [x for x in srcs_list if x.extension == "metal"]

    srcs_hdrs_list = [x for x in srcs_list if x.extension == "h" or x.extension == "hpp"]

    air_files = _compile_metals(srcs_metal_list, srcs_hdrs_list, trans_hdr_paths, ctx)

    trans_airs = get_transitive_airs(air_files, ctx.attr.deps)

    args = ctx.actions.args()
    args.add("metal")
    if _is_debug(ctx):
        args.add("-frecord-sources")
        args.add("-g")

    version_flag = _get_os_version_flag(ctx)
    if version_flag:
        args.add(version_flag)

    args.add("-o", metallib_file)
    args.add_all(trans_airs)

    apple_support.run(
        actions = ctx.actions,
        xcode_config = ctx.attr._xcode_config[apple_common.XcodeVersionConfig],
        apple_fragment = ctx.fragments.apple,
        inputs = trans_airs,
        outputs = [metallib_file],
        executable = "/usr/bin/xcrun",
        arguments = [args],
        mnemonic = "MetallibLink",
    )

    return [DefaultInfo(files = depset([metallib_file]))]

metal_binary = rule(
    implementation = _metal_binary_impl,
    fragments = ["apple"],
    attrs = dicts.add(
        apple_support.action_required_attrs(),
        {
            "srcs": attr.label_list(allow_files = [".metal", ".h", ".hpp"]),
            "deps": attr.label_list(),
            "copts": attr.string_list(),
            "out": attr.output(),
        },
    ),
)
