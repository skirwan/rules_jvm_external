# Stripped down version of a java_import Starlark rule, without invoking ijar
# to create interface jars.

# Inspired by Square's implementation of `raw_jvm_import` [0] and discussions
# on the GitHub thread [1] about ijar's interaction with Kotlin JARs.
#
# [0]: https://github.com/square/bazel_maven_repository/pull/48
# [1]: https://github.com/bazelbuild/bazel/issues/4549

def _jvm_import_impl(ctx):
    if len(ctx.files.jars) != 1:
        fail("Please only specify one jar to import in the jars attribute.")

    injar = ctx.files.jars[0]
    manifest_update_file = ctx.actions.declare_file(injar.basename + ".target_label_manifest", sibling = injar)
    ctx.actions.expand_template(
        template = ctx.file._manifest_template,
        output = manifest_update_file,
        substitutions = {
            "{TARGETLABEL}": "%s" % ctx.label,
        },
    )

    outjar_name = injar.basename[:-4] + '_stamped.jar'
    outjar = ctx.actions.declare_file(outjar_name, sibling = injar)
    ctx.actions.run_shell(
        inputs = [injar, manifest_update_file] + ctx.files._host_javabase,
        outputs = [outjar],
        command = " && ".join([
            # Make a copy of the original jar, since `jar(1)` modifies the jar in place.
            "cp {input_jar} {output_jar}".format(input_jar = injar.path, output_jar = outjar.path),
            # Set the write bit on the copied jar.
            "chmod +w {output_jar}".format(output_jar = outjar.path),
            # If the jar is signed do not modify the manifest because it will
            # make the signature invalid. Otherwise append the Target-Label
            # manifest attribute using `jar umf`.  Since that will update the
            # timestamp of the JAR entry to 'now' and result in a different 
            # hash (thereby making everything downstream uncacheable), take
            # special care to make sure we're reproducible.
            # NB: On some systems zip will not properly take file timestamps
            # when updating existing entries; that's why we use jar.
            # Based on a pull request submitted by kevingessner, edited to work
            # on macOS.
            "(unzip -l {output_jar} | grep -qE 'META-INF/.*\\.SF') || \
                ({jar} xf {manifest_update_file} {output_jar} > /dev/null 2>&1 && \
                {jar} -q {output_jar} META-INF/MANIFEST.MF && \
                touch -t 201001010000.00 META-INF/MANIFEST.MF && \
                {jar} uf {output_jar} META-INF/MANIFEST.MF || true)".format(
                jar = "%s/bin/jar" % ctx.attr._host_javabase[java_common.JavaRuntimeInfo].java_home,
                manifest_update_file = manifest_update_file.path,
                output_jar = outjar.path,
            ),
        ]),
        mnemonic = "StampJar",
        progress_message = "Stamping manifest of %s" % ctx.label,
    )

    return [
        DefaultInfo(
            files = depset([outjar]),
        ),
        JavaInfo(
            compile_jar = outjar,
            output_jar = outjar,
            source_jar = ctx.file.srcjar,
            deps = [
                dep[JavaInfo]
                for dep in ctx.attr.deps
                if JavaInfo in dep
            ],
            neverlink = ctx.attr.neverlink,
        ),
    ]

jvm_import = rule(
    attrs = {
        "jars": attr.label_list(
            allow_files = True,
            mandatory = True,
            cfg = "target",
        ),
        "srcjar": attr.label(
            allow_single_file = True,
            mandatory = False,
            cfg = "target",
        ),
        "deps": attr.label_list(
            default = [],
            providers = [JavaInfo],
        ),
        "neverlink": attr.bool(
            default = False,
        ),
        "_host_javabase": attr.label(
            cfg = "host",
            default = Label("@bazel_tools//tools/jdk:current_host_java_runtime"),
            providers = [java_common.JavaRuntimeInfo],
        ),
        "_manifest_template": attr.label(
            default = Label("@rules_jvm_external//private/templates:manifest_target_label.tpl"),
            allow_single_file = True,
        ),
    },
    implementation = _jvm_import_impl,
    provides = [JavaInfo],
)
