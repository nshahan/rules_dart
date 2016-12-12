# Copyright 2016 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Internal implemenation utility functions for Dart rules.

WARNING: NOT A PUBLIC API.

This code is public only by virtue of the fact that Bazel does not yet support
a mechanism for enforcing limitied visibility of Skylark rules. This code makes
no gurantees of API stability and is intended solely for use by the Dart rules.
"""

_third_party_prefix = "third_party/dart/"

def assert_third_party_licenses(ctx):
  """Asserts license attr on non-testonly third-party packages."""
  if (not ctx.attr.testonly
      and not ctx.attr.license_files
      and ctx.label.package.startswith(_third_party_prefix)):
    fail("%s lacks license_files attribute, " % ctx.label +
         "required for all non-testonly third-party Dart library rules")

def collect_files(dart_ctx):
  srcs = set(dart_ctx.srcs)
  data = set(dart_ctx.data)
  for d in dart_ctx.transitive_deps.values():
    srcs += d.dart.srcs
    data += d.dart.data
  return (srcs, data)

def _collect_transitive_deps(deps):
  """Collects transitive closure of deps.

  Args:
    deps: input deps Target collection. All targets must have a 'dart' provider.

  Returns:
    Transitive closure of deps.
  """
  transitive_deps = {}
  for dep in deps:
    transitive_deps += dep.dart.transitive_deps
    transitive_deps["%s" % dep.dart.label] = dep
  return transitive_deps

def _label_to_dart_package_name(label):
  """Returns the Dart package name for the specified label.

  Packages under //third_party/dart resolve to their external Pub package names.
  All other packages resolve to a unique identifier based on their repo path.

  Examples:
    //foo/bar/baz:           foo.bar.baz
    //third_party/dart/args: args
    //third_party/guice:     third_party.guice

  Restrictions:
    Since packages outside of //third_party/dart are identified by their path
    components joined by periods, it is an error for the label package to
    contain periods.

  Args:
    label: the label whose package name is to be returned.

  Returns:
    The Dart package name associated with the label.
  """
  package_name = label.package
  if label.package.startswith(_third_party_prefix):
    third_party_path = label.package[len(_third_party_prefix):]
    if "/" not in third_party_path:
      package_name = third_party_path
  if label.workspace_root.startswith("external/"):
    package_name = label.workspace_root[len("external/"):]
  if "." in package_name:
    fail("Dart package paths may not contain '.': " + label.package)
  return package_name.replace("/", ".")

def _new_dart_context(label,
                      package,
                      lib_root,
                      srcs=None,
                      data=None,
                      deps=None,
                      strong_summary=None,
                      transitive_deps=None):
  return struct(
      label=label,
      package=package,
      lib_root=lib_root,
      srcs=set(srcs or []),
      data=set(data or []),
      deps=deps or [],
      strong_summary=None,
      transitive_deps=dict(transitive_deps or {}),
  )

def make_dart_context(label,
                      package=None,
                      lib_root=None,
                      srcs=None,
                      data=None,
                      deps=None,
                      pub_pkg_name=None,
                      strong_summary=None):
  if not package:
    if not pub_pkg_name:
      package = _label_to_dart_package_name(label)
    else:
      package = pub_pkg_name
  if not lib_root:
    lib_root = "lib/"

  srcs = set(srcs or [])
  data = set(data or [])
  deps = deps or []
  transitive_deps = _collect_transitive_deps(deps)
  return struct(
      label=label,
      package=package,
      lib_root=lib_root,
      srcs=srcs,
      data=data,
      deps=deps,
      strong_summary=strong_summary,
      transitive_deps=transitive_deps,
  )

def _merge_dart_context(dart_ctx1, dart_ctx2):
  """Merges two dart contexts whose package and lib_root must be identical."""
  if dart_ctx1.package != dart_ctx2.package:
    fail("Incompatible packages: %s and %s" % (dart_ctx1.package,
                                               dart_ctx2.package))
  if dart_ctx1.lib_root != dart_ctx2.lib_root:
    fail("Incompatible lib_roots for package %s:\n" % dart_ctx1.package +
         "  %s declares: %s\n" % (dart_ctx1.label, dart_ctx1.lib_root) +
         "  %s declares: %s\n" % (dart_ctx2.label, dart_ctx2.lib_root) +
         "Targets in the same package must declare the same lib_root")

  return _new_dart_context(
      label=dart_ctx1.label,
      package=dart_ctx1.package,
      lib_root=dart_ctx1.lib_root,
      srcs=dart_ctx1.srcs + dart_ctx2.srcs,
      data=dart_ctx1.data + dart_ctx2.data,
      deps=dart_ctx1.deps + dart_ctx2.deps,
      strong_summary=dart_ctx1.strong_summary,
      transitive_deps=dart_ctx1.transitive_deps + dart_ctx2.transitive_deps,
  )

def _collect_dart_context(dart_ctx, transitive=True, include_self=True):
  """Collects and returns dart contexts."""
  # Collect direct or transitive deps.
  dart_ctxs = [dart_ctx]
  if transitive:
    dart_ctxs += [d.dart for d in dart_ctx.transitive_deps.values()]
  else:
    dart_ctxs += [d.dart for d in dart_ctx.deps]

  # Optionally, exclude all self-packages.
  if not include_self:
    dart_ctxs = [c for c in dart_ctxs if c.package != dart_ctx.package]

  # Merge Dart context by package.
  ctx_map = {}
  for dc in dart_ctxs:
    if dc.package in ctx_map:
      dc = _merge_dart_context(ctx_map[dc.package], dc)
    ctx_map[dc.package] = dc
  return ctx_map

def package_spec_action(ctx, dart_ctx, output):
  """Creates an action that generates a Dart package spec.

  Arguments:
    ctx: The rule context.
    dart_ctx: The Dart context.
    output: The output package_spec file.
  """
  # There's a 1-to-many relationship between packages and targets, but
  # collect_transitive_packages() asserts that their lib_roots are the same.
  dart_ctxs = _collect_dart_context(dart_ctx,
                                    transitive=True,
                                    include_self=True).values()

  # Generate the content.
  content = "# Generated by Bazel\n"
  for dc in dart_ctxs:
    path_to_lib_root = "lib/"
    # print(dc.label.package, dc.label.workspace_root)
    if dc.label.package.startswith("vendor/"):
      path_to_lib_root = "%s/%s" % (dc.label.package[len("vendor/"):], dc.lib_root)
    #   print("VENDOR: ", dc.label.package, dc.label.workspace_root, path_to_lib_root)
    elif dc.label.workspace_root.startswith("external/"):
      path_to_lib_root = "../%s/%s" % (dc.label.workspace_root[len("external/"):], dc.lib_root)
    #   print("EXTERNAL: ", dc.label.package, dc.label.workspace_root, path_to_lib_root)
    # else:
    #   print("EVERYTHING ELSE: ", dc.label.package, dc.label.workspace_root, path_to_lib_root)

    relative_lib_root = _relative_path(dart_ctx.label.package, path_to_lib_root)
    if dc.package:
      content += "%s:%s\n" % (dc.package, relative_lib_root)

    # print(dc.label.package, dc.label.workspace_root, relative_lib_root)
  # Emit the package spec.
  ctx.file_action(
      output=output,
      content=content,
  )

def _relative_path(from_dir, to_path):
  """Returns the relative path from a directory to a path via the repo root."""
  if not from_dir:
    return to_path
  return "../" * (from_dir.count("/") + 1) + to_path

def layout_action(ctx, srcs, output_dir):
  """Generates a flattened directory of sources.

  For each file f in srcs, a file is emitted at output_dir/f.short_path.
  Returns a dict mapping short_path to the emitted file.

  Args:
    ctx: the build context.
    srcs: the set of input srcs to be flattened.
    output_dir: the full output directory path into which the files are emitted.

  Returns:
    A map from input file short_path to File in output_dir.
  """
  commands = []
  output_files = {}
  # TODO(cbracken) extract next two lines to func
  if not output_dir.endswith("/"):
    output_dir += "/"
  for src_file in srcs:
    short_better_path = src_file.short_path
    if "vendor_" in short_better_path:
      short_better_path = short_better_path.replace("vendor_", "")
    if short_better_path.startswith('../'):
      dest_file = ctx.new_file(output_dir + short_better_path.replace("../", ""))
    else:
      dest_file = ctx.new_file(output_dir + short_better_path)
    dest_dir = dest_file.path[:dest_file.path.rfind("/")]
    link_target = _relative_path(dest_dir, src_file.path)
    commands += ["ln -s '%s' '%s'" % (link_target, dest_file.path)]
    output_files[src_file.short_path] = dest_file

  # Emit layout script.
  layout_cmd = ctx.new_file(ctx.label.name + "_layout.sh")
  ctx.file_action(
      output=layout_cmd,
      content="#!/bin/bash\n" + "\n".join(commands),
      executable=True,
  )

  # Invoke the layout action.
  ctx.action(
      inputs=list(srcs),
      outputs=output_files.values(),
      executable=layout_cmd,
      progress_message="Building flattened source layout for %s" % ctx,
      mnemonic="DartLayout",
  )
  return output_files

# Check if `srcs` contains at least some dart files
def has_dart_sources(srcs):
  for n in srcs:
    if n.path.endswith(".dart"):
      return True
  return False

def filter_files(filetypes, files):
  """Filters a list of files based on a list of strings."""
  filtered_files = []
  for file_to_filter in files:
    for filetype in filetypes:
      if str(file_to_filter).endswith(filetype):
        filtered_files.append(file_to_filter)
        break

  return filtered_files

def make_package_uri(dart_ctx, short_path, prefix=""):
  if short_path.startswith("../"):
    short_path = short_path.replace("../","")
  if short_path.startswith(dart_ctx.lib_root):
    return "package:%s/%s" % (
        dart_ctx.package, short_path[len(dart_ctx.lib_root):])
  else:
    return "file:///%s%s" % (prefix, short_path)

def compute_layout(srcs):
  """Computes a dict mapping short_path to file.

  This is similar to the dict returned by layout_action, except that
  the files in the dict are the original files rather than symbolic
  links.
  """
  output_files = {}
  for src_file in srcs:
    output_files[src_file.short_path] = src_file
  return output_files

dart_filetypes = [".dart"]

api_summary_extension = "api.ds"
