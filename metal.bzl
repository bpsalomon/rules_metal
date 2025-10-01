""" Rules for organizing and compiling Metal. """

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@bazel_skylib//lib:paths.bzl", "paths")
load("@build_bazel_apple_support//lib:apple_support.bzl", "apple_support")
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

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
            args.add("-gline-tables-only")

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
        args.add("-gline-tables-only")

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

MetalDebugInfo = provider(
    doc = "Provider for collecting Metal binary targets",
    fields = {
        "targets": "depset of target label strings",
    },
)

def _metal_debug_aspect_impl(target, ctx):
    """Aspect that collects all metal_binary targets."""
    metal_binaries = []

    # Check if this target itself is a metal_binary (produces a .metallib file)
    if hasattr(target, "files"):
        for f in target.files.to_list():
            if f.extension == "metallib":
                metal_binaries.append(str(target.label))
                break

    # Collect metal binaries from dependencies (aspect handles recursion)
    transitive_metal_binaries = []
    if hasattr(ctx.rule.attr, "deps"):
        for dep in ctx.rule.attr.deps:
            if MetalDebugInfo in dep:
                transitive_metal_binaries.append(dep[MetalDebugInfo].targets)

    if hasattr(ctx.rule.attr, "data"):
        for dep in ctx.rule.attr.data:
            if MetalDebugInfo in dep:
                transitive_metal_binaries.append(dep[MetalDebugInfo].targets)

    if hasattr(ctx.rule.attr, "implementation_deps"):
        for dep in ctx.rule.attr.implementation_deps:
            if MetalDebugInfo in dep:
                transitive_metal_binaries.append(dep[MetalDebugInfo].targets)

    # Return a depset combining our findings with transitive ones
    return [
        MetalDebugInfo(
            targets = depset(
                direct = metal_binaries,
                transitive = transitive_metal_binaries,
            ),
        ),
    ]

metal_debug_aspect = aspect(
    implementation = _metal_debug_aspect_impl,
    attr_aspects = ["deps", "data", "implementation_deps"],
)

def _xcode_metal_debug_helper_impl(ctx):
    """Generates a script to create symlinks for Xcode GPU shader debugging."""

    # Get all metallib targets from dependencies via the aspect
    metallib_targets = []
    for dep in ctx.attr.deps:
        if MetalDebugInfo in dep:
            metallib_targets.extend(dep[MetalDebugInfo].targets.to_list())

    # Generate the script
    script = ctx.actions.declare_file(ctx.label.name + ".sh")

    script_content = """#!/bin/bash
# Generated script to create symlinks for Xcode GPU shader debugging
#
# Usage:
#   {script_name}                      # Interactive mode (prompts for temp dir)
#   {script_name} <xcode_temp_directory>  # Direct mode (uses provided path)
#
# When Xcode captures a GPU frame and extracts Metal sources, run this script
# with the temp directory path to create necessary symlinks for includes to resolve.
#
# Example:
#   {script_name} /var/folders/.../T/780970914.71
#
# Metallibs used by this app:
{metallib_list}

set -e

# Check if temp dir was provided as argument
if [ -n "$1" ]; then
    TEMP_DIR="$1"
else
    # Interactive mode - prompt for temp dir
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Xcode Metal GPU Shader Debugging Setup"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Steps:"
    echo "  1. Run your app from Xcode"
    echo "  2. Capture GPU frame: Debug → Capture GPU Frame (⌘⌥G)"
    echo "  3. Click on a shader to view it"
    echo "  4. Copy the temp directory from any compile error"
    echo ""
    echo "The temp directory path looks like:"
    echo "  /var/folders/.../T/780970914.71"
    echo "            (copy up to here ^)"
    echo ""
    echo -n "Enter the temp directory path: "
    read TEMP_DIR
fi

if [ -z "$TEMP_DIR" ]; then
    echo "Error: No path provided"
    exit 1
fi

if [ ! -d "$TEMP_DIR" ]; then
    echo "Error: Directory does not exist: $TEMP_DIR"
    echo ""
    echo "Make sure you:"
    echo "  - Captured a GPU frame first"
    echo "  - Copied the full path up to /T/XXXXXX.XX"
    exit 1
fi

echo "Creating symlinks for Xcode GPU shader debugging in: $TEMP_DIR"

# Function to create symlinks in a directory
# Prefers include directories in the same numbered subdirectory
create_symlinks_in_dir() {{
    local target_dir="$1"

    # Extract the numbered subdirectory from target_dir (e.g., /path/src/HASH/0/... -> 0)
    local target_subdir=$(echo "$target_dir" | sed -n 's#.*/src/[^/]*/\\([0-9]*\\)/.*#\\1#p')

    # Find all include directories and create symlinks
    # Process them so that include dirs in the same numbered subdir come first
    find "$TEMP_DIR" -type d -name "include" | sort | while read -r include_path; do
        lib_base=$(dirname "$include_path")
        lib_name=$(basename "$lib_base")

        # Extract numbered subdirectory from this include path
        local include_subdir=$(echo "$include_path" | sed -n 's#.*/src/[^/]*/\\([0-9]*\\)/.*#\\1#p')

        # Determine virtual prefix (e.g., "applelib" -> "apple", "drawlib" -> "draw")
        case "$lib_name" in
            *lib) virtual_name="${{lib_name%lib}}" ;;
            *) virtual_name="$lib_name" ;;
        esac

        # If symlink doesn't exist, create it
        # If it exists but points to different subdir and we have matching subdir, replace it
        if [ ! -e "$target_dir/$virtual_name" ]; then
            ln -sf "$include_path" "$target_dir/$virtual_name"
            echo "  Created symlink: $target_dir/$virtual_name -> $include_path"
        elif [ "$target_subdir" = "$include_subdir" ]; then
            # This include is in the same numbered subdirectory, prefer it
            current_target=$(readlink "$target_dir/$virtual_name" 2>/dev/null || echo "")
            current_subdir=$(echo "$current_target" | sed -n 's#.*/src/[^/]*/\\([0-9]*\\)/.*#\\1#p')
            if [ "$current_subdir" != "$target_subdir" ]; then
                rm -f "$target_dir/$virtual_name"
                ln -sf "$include_path" "$target_dir/$virtual_name"
                echo "  Updated symlink: $target_dir/$virtual_name -> $include_path (same subdirectory)"
            fi
        fi
    done
}}

# Find all directories containing .metal files and create symlinks
find "$TEMP_DIR" -type f -name "*.metal" | while read -r metalfile; do
    msldir=$(dirname "$metalfile")

    # Skip if we've already processed this directory
    if [ -f "$msldir/.symlinks_created" ]; then
        continue
    fi

    echo "Processing: $msldir"

    # Create symlinks in this directory
    create_symlinks_in_dir "$msldir"

    # Also create symlinks in the shared/ subdirectory if it exists
    if [ -d "$msldir/shared" ]; then
        create_symlinks_in_dir "$msldir/shared"
    fi

    # Mark this directory as processed
    touch "$msldir/.symlinks_created"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Setup complete! Go back to Xcode and view your shader."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
""".format(
        script_name = script.short_path,
        metallib_list = "\n".join(["#   - " + t for t in metallib_targets]),
    )

    ctx.actions.write(
        output = script,
        content = script_content,
        is_executable = True,
    )

    return [DefaultInfo(
        files = depset([script]),
        executable = script,
    )]

_xcode_metal_debug_helper = rule(
    implementation = _xcode_metal_debug_helper_impl,
    attrs = {
        "deps": attr.label_list(aspects = [metal_debug_aspect]),
    },
    executable = True,
)

def cc_binary_with_metal_debug(name, **kwargs):
    """Wrapper for cc_binary that adds Xcode GPU shader debugging support.

    Args:
        name: Name of the binary
        **kwargs: All other arguments passed to cc_binary

    Usage:
        cc_binary_with_metal_debug(
            name = "my_app",
            srcs = ["main.cpp"],
            deps = [...],
        )

        # Then run: bazel run //path/to:my_app_copy_metal_hdrs_to_trace
    """
    native.cc_binary(name = name, **kwargs)
    metal_debug_script(
        name = name + "_copy_metal_hdrs_to_trace",
        deps = kwargs.get("deps", []) + kwargs.get("data", []),
    )

def cc_library_with_metal_debug(name, **kwargs):
    """Wrapper for cc_library that adds Xcode GPU shader debugging support.

    Args:
        name: Name of the library
        **kwargs: All other arguments passed to cc_library

    Usage:
        cc_library_with_metal_debug(
            name = "my_lib",
            srcs = ["lib.cpp"],
            deps = [...],
        )

        # Then run: bazel run //path/to:my_lib_copy_metal_hdrs_to_trace
    """
    native.cc_library(name = name, **kwargs)
    metal_debug_script(
        name = name + "_copy_metal_hdrs_to_trace",
        deps = kwargs.get("deps", []) + kwargs.get("data", []),
    )

def swift_library_with_metal_debug(name, **kwargs):
    """Wrapper for swift_library that adds Xcode GPU shader debugging support.

    Args:
        name: Name of the library
        **kwargs: All other arguments passed to swift_library

    Usage:
        load("@rules_metal//:metal.bzl", "swift_library_with_metal_debug")

        swift_library_with_metal_debug(
            name = "MyLib",
            srcs = ["MyLib.swift"],
            deps = [...],
        )

        # Then run: bazel run //path/to:MyLib_copy_metal_hdrs_to_trace
    """
    swift_library(name = name, **kwargs)
    metal_debug_script(
        name = name + "_copy_metal_hdrs_to_trace",
        deps = kwargs.get("deps", []) + kwargs.get("data", []),
    )

def metal_debug_script(name, deps):
    """Creates Xcode GPU debug helper script(s) for existing targets.

    This is useful for Apple application targets (macos_application, ios_application, etc.)
    that can't use cc_binary_with_metal_debug.

    Args:
        name: Base name for the debug targets (e.g., "MyApp_copy_metal_hdrs_to_trace")
        deps: Dependencies to scan for metal binaries

    Creates:
        - {name}: The debug script (supports both interactive and direct modes)

    Usage:
        macos_application(
            name = "MyApp",
            deps = ["MyAppLib"],
        )

        metal_debug_script(
            name = "MyApp_copy_metal_hdrs_to_trace",
            deps = ["MyAppLib"],
        )

        # Run from command line (auto-rebuilds and prompts for temp dir):
        bazel run //path/to:MyApp_copy_metal_hdrs_to_trace
    """
    _xcode_metal_debug_helper(
        name = name,
        deps = deps,
    )
