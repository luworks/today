#!/usr/bin/env python3
"""Read-only release checks. JSON contains fixed check codes, never command output."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import subprocess
import sys
import tempfile
import zipfile
import importlib.util

_graph_spec = importlib.util.spec_from_file_location("release_graph", Path(__file__).with_name("graph.py"))
graph = importlib.util.module_from_spec(_graph_spec)
_graph_spec.loader.exec_module(graph)

ROOT = Path(__file__).resolve().parents[2]
PRODUCTS = {'One': 'com.luworks.today', 'TodayWidgets': 'com.luworks.today.widgets',
            'ShareExtension': 'com.luworks.today.share'}
PROFILES = {'One': 'TODAY_APP_PROFILE', 'TodayWidgets': 'TODAY_WIDGET_PROFILE',
            'ShareExtension': 'TODAY_SHARE_PROFILE'}
GROUP = 'group.com.luworks.today'


class Blocked(Exception):
    pass


def run(args, root=ROOT):
    # No shell, no interactive authentication, no output copied into reports.
    env = dict(os.environ, BUNDLE_FROZEN='true', BUNDLE_GEMFILE=str(root / 'Gemfile'),
               FASTLANE_SKIP_UPDATE_CHECK='1', FASTLANE_OPT_OUT_USAGE='1', CI='1')
    try:
        p = subprocess.run(args, cwd=root, env=env, capture_output=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        raise Blocked('command_unavailable') from None
    if p.returncode:
        raise Blocked('command_failed')
    return p.stdout


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def load_plist(path):
    with path.open('rb') as f:
        return plistlib.load(f)


def require(ok, code):
    if not ok:
        raise Blocked(code)


def lock_hashes(root):
    paths = ['Gemfile', 'Gemfile.lock', 'scripts/release/tool-lock.json']
    # Only the versioned authority is required to be tracked. Xcode generates an
    # ignored workspace copy; it must match bytes, but is not a tracked input.
    authority = 'ios/Dependencies/Package.resolved'
    paths.append(authority)
    for duplicate in (root / 'ios').rglob('Package.resolved'):
        if duplicate == root / authority or any(p in duplicate.parts for p in ('.build', 'checkouts')):
            continue
        require(duplicate.read_bytes() == (root / authority).read_bytes(), 'workspace_package_lock_mismatch')
    return {p: sha(root / p) for p in paths}


def check_git(root, commit):
    require(bool(re.fullmatch(r'[0-9a-f]{40}', commit)), 'commit_required')
    require(run(['git', 'rev-parse', 'HEAD'], root).decode().strip() == commit, 'commit_mismatch')
    require(not run(['git', 'status', '--porcelain', '--untracked-files=all'], root).strip(), 'worktree_dirty')
    require(not run(['git', 'submodule', 'status', '--recursive'], root).strip(), 'submodules_not_supported')
    for path in lock_hashes(root):
        run(['git', 'ls-files', '--error-unmatch', path], root)
    return commit


def check_tools(root):
    lock = json.loads((root / 'scripts/release/tool-lock.json').read_text())
    require(run(['ruby', '-e', 'print RUBY_VERSION'], root).decode() == lock['ruby'], 'ruby_lock_mismatch')
    require(run(['bundle', '--version'], root).decode().strip() in
            (lock['bundler'], 'Bundler version ' + lock['bundler']), 'bundler_lock_mismatch')
    text = (root / 'Gemfile.lock').read_text()
    require(f'    fastlane ({lock["fastlane"]})\n' in text and
            bool(re.search(r'BUNDLED WITH\n\s+' + re.escape(lock['bundler']) + r'\s*$', text)), 'gem_lock_mismatch')
    run(['bundle', 'check'], root)
    # Executes only installed locked code; no gem downloads or Fastlane update check.
    actual = run(['bundle', 'exec', 'ruby', '-e', 'require "fastlane/version"; print Fastlane::VERSION'], root)
    require(actual.decode() == lock['fastlane'], 'fastlane_lock_mismatch')
    require(run(['xcodebuild', '-version'], root).decode().strip() == lock['xcode'], 'xcode_lock_mismatch')
    run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], root)
    return lock_hashes(root)


def check_project(root):
    project = root / 'ios/Today.xcodeproj'
    require((project / 'project.pbxproj').is_file(), 'generated_project_missing')
    require((project / 'xcshareddata/xcschemes/Today.xcscheme').is_file(), 'shared_scheme_missing')
    # No project generation or build-settings command here (those may resolve packages).
    for name in PRODUCTS:
        ent = load_plist(root / f'ios/{name}.entitlements')
        require(ent.get('com.apple.security.application-groups') == [GROUP], 'source_app_group_mismatch')
        expected = {'com.apple.security.application-groups': [GROUP]}
        if name == 'One':
            expected.update({'com.apple.developer.healthkit': True, 'com.apple.developer.healthkit.access': []})
        require(ent == expected, 'source_capabilities_mismatch')
    return graph.check(root, run, require)


def profile(path, name, team, root, identities=None, leaf_certificate=None):
    require(bool(re.fullmatch(r'[A-Z0-9]{10}', team)), 'signing_team_required')
    require(path.is_file(), 'provisioning_profile_missing')
    data = plistlib.loads(run(['security', 'cms', '-D', '-i', str(path)], root))
    now = dt.datetime.now(dt.timezone.utc)
    expiry = data['ExpirationDate'].replace(tzinfo=dt.timezone.utc)
    require(expiry > now, 'provisioning_profile_expired')
    ent = data['Entitlements']
    require(data.get('TeamIdentifier') == [team] and
            ent.get('com.apple.developer.team-identifier') == team and
            ent.get('application-identifier') == team + '.' + PRODUCTS[name], 'profile_identity_mismatch')
    require(ent.get('get-task-allow') is False and not data.get('ProvisionedDevices') and
            not data.get('ProvisionsAllDevices'), 'app_store_profile_required')
    require(ent.get('com.apple.security.application-groups') == [GROUP], 'profile_app_group_mismatch')
    expected = load_plist(root / f'ios/{name}.entitlements')
    require(all(ent.get(k) == v for k, v in expected.items()), 'profile_capabilities_mismatch')
    certs = {hashlib.sha1(c).hexdigest().upper() for c in data.get('DeveloperCertificates', [])}
    require(bool(certs), 'profile_certificate_missing')
    if leaf_certificate is not None:
        require(sha1_certificate(leaf_certificate) in certs, 'archive_certificate_not_in_profile')
    if identities is not None:
        require(bool(certs & identities), 'matching_private_signing_identity_missing')
    return ent


def sha1_certificate(path):
    return hashlib.sha1(path.read_bytes()).hexdigest().upper()


def check_signing(root, team, env, version=None, build=None):
    require(bool(re.fullmatch(r'[A-Z0-9]{10}', team)), 'signing_team_required')
    raw = run(['security', 'find-identity', '-v', '-p', 'codesigning'], root).decode()
    identities = set(re.findall(r'\b([A-F0-9]{40})\s+"Apple Distribution:', raw))
    require(bool(identities), 'distribution_identity_missing')
    for name, key in PROFILES.items():
        require(bool(env.get(key)), 'selected_profiles_required')
        profile(Path(env[key]), name, team, root, identities)
    # Read build settings only; disable SwiftPM resolution and updates. Do not
    # pass signing overrides, provisioning updates or account authentication flags.
    check_project(root)
    raw = run(['xcodebuild', '-project', 'ios/Today.xcodeproj', '-alltargets',
               '-configuration', 'Release', '-sdk', 'iphoneos',
               '-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile', '-skipPackageUpdates',
               '-showBuildSettings', '-json'], root)
    rows = json.loads(raw)
    settings = {r['buildSettings'].get('PRODUCT_NAME'): r['buildSettings'] for r in rows}
    for name, bundle_id in PRODUCTS.items():
        require(name in settings, 'release_product_settings_missing')
        b = settings[name]
        data = plistlib.loads(run(['security', 'cms', '-D', '-i', env[PROFILES[name]]], root))
        require((version is None or b.get('MARKETING_VERSION') == version) and
                (build is None or str(b.get('CURRENT_PROJECT_VERSION')) == build) and
                (name != 'One' or b.get('PRODUCT_MODULE_NAME') == 'TodayApp') and
                b.get('PRODUCT_BUNDLE_IDENTIFIER') == bundle_id and
                b.get('DEVELOPMENT_TEAM') == team and b.get('CODE_SIGN_STYLE') == 'Manual' and
                b.get('CODE_SIGNING_ALLOWED') == 'YES' and
                b.get('PROVISIONING_PROFILE_SPECIFIER') in (data.get('Name'), data.get('UUID')) and
                bool(b.get('PROVISIONING_PROFILE_SPECIFIER')) and
                b.get('CODE_SIGN_IDENTITY', '').startswith('Apple Distribution'),
                'release_signing_settings_mismatch')
    return 'existing_identity_and_profiles_available'


class Report:
    def __init__(self, action):
        self.data = {'schema': 1, 'action': action, 'status': 'ready', 'checks': {},
                     'evidence': 'local_checks_only', 'distribution': 'not_authorized',
                     'offline_scanner': 'unavailable'}

    def check(self, key, fn):
        try:
            fn()
            self.data['checks'][key] = {'status': 'ready'}
        except Exception as e:
            code = str(e) if isinstance(e, Blocked) else 'invalid_or_missing_input'
            self.data['checks'][key] = {'status': 'blocked', 'code': code}
            self.data['status'] = 'blocked'


def preflight(root, args, env):
    report = Report('preflight')
    report.check('release_acceptance', lambda: check_release_acceptance(root, report))
    report.check('release_metadata', lambda: metadata(args))
    report.check('git_commit_clean', lambda: check_git(root, args.commit))
    report.check('locked_tools', lambda: check_tools(root))
    report.check('generated_project', lambda: check_project(root))
    report.check('signing_environment', lambda: check_signing(root, args.team, env, args.version, args.build))
    return report


def check_release_acceptance(root, report):
    # Use the test authority's existing pending gates, including known red audits.
    manifest = json.loads((root / 'tests/testing/groups.json').read_text())
    pending = manifest['groups']['release']['pending']
    require(isinstance(pending, list) and all(isinstance(item, str) and item for item in pending),
            'release_acceptance_manifest_invalid')
    report.data['pending_acceptance'] = pending
    require(not pending, 'release_acceptance_pending')


def metadata(args, local=False):
    require(bool(re.fullmatch(r'\d+\.\d+(?:\.\d+)?', args.version)), 'version_required')
    require(bool(re.fullmatch(r'[1-9]\d*', args.build)), 'build_required')
    if not local:
        require(bool(re.fullmatch(r'[A-Z0-9]{10}', args.team)), 'signing_team_required')


def inventory(archive):
    require(isinstance(archive, Path), 'archive_required')
    require(archive.is_dir() and archive.suffix == '.xcarchive', 'archive_missing')
    result = {}
    for path in sorted(archive.rglob('*')):
        require(not path.is_symlink(), 'archive_symlink_refused')
        if path.is_file() and path != archive / 'release-provenance.json':
            result[str(path.relative_to(archive))] = sha(path)
    require(bool(result), 'archive_empty')
    return result


def seal(root, args, local=False):
    # Local provenance, not an attestation. Both modes verify Mach-O UUIDs; only
    # distribution mode verifies Apple signatures. Seal after archive exit only.
    check_git(root, args.commit)
    check_tools(root)
    data = {'schema': 1, 'commit': args.commit, 'version': args.version, 'build': args.build,
            'tool_locks': lock_hashes(root), 'files': inventory(args.archive),
            'mode': 'unsigned_local' if local else 'signed_distribution'}
    target = args.archive / 'release-provenance.json'
    with target.open('x') as f:
        json.dump(data, f, sort_keys=True)


def uuids(path, root):
    text = run(['xcrun', 'dwarfdump', '--uuid', str(path)], root).decode()
    rows = re.findall(r'^UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\)', text, re.M)
    require(bool(rows) and len(rows) == len(set(rows)), 'macho_uuid_missing_or_duplicate')
    require(all(arch in ('arm64', 'arm64e') for _, arch in rows), 'device_architecture_required')
    return {(u.upper(), arch) for u, arch in rows}


def validate_archive(root, args, local=False):
    archive = args.archive
    actual = inventory(archive)
    receipt = json.loads((archive / 'release-provenance.json').read_text())
    require(receipt.get('schema') == 1 and receipt['commit'] == args.commit and
            receipt['version'] == args.version and receipt['build'] == args.build and
            receipt['tool_locks'] == lock_hashes(root), 'archive_provenance_mismatch')
    require(receipt.get('mode', 'signed_distribution') ==
            ('unsigned_local' if local else 'signed_distribution'), 'archive_readiness_mode_mismatch')
    require(receipt['files'] == actual, 'archive_content_changed')
    apps = list((archive / 'Products/Applications').glob('*.app'))
    require(len(apps) == 1 and apps[0].name == 'One.app', 'app_product_mismatch')
    app = apps[0]
    info = load_plist(archive / 'Info.plist')['ApplicationProperties']
    require(info.get('ApplicationPath') == 'Applications/One.app' and
            info.get('CFBundleIdentifier') == PRODUCTS['One'] and
            info.get('CFBundleShortVersionString') == args.version and
            str(info.get('CFBundleVersion')) == args.build, 'archive_metadata_mismatch')
    validate_resources(root, app)
    validate_products(root, args, archive, app, local=local)
    validate_link_maps(root, args, actual)


def validate_products(root, args, archive, app, local=False):
    extensions = list((app / 'PlugIns').glob('*'))
    require({p.name for p in extensions} == {'TodayWidgets.appex', 'ShareExtension.appex'}, 'extension_embeds_mismatch')
    require(not list(app.rglob('*.app')) and len(list(app.rglob('*.appex'))) == 2, 'unexpected_nested_product')
    symbols = {}
    for dwarf in (archive / 'dSYMs').glob('*.dSYM/Contents/Resources/DWARF/*'):
        for uid in uuids(dwarf, root):
            require(uid not in symbols, 'duplicate_dsym_uuid')
            symbols[uid] = dwarf
    binaries = []
    for name in PRODUCTS:
        bundle = app if name == 'One' else app / f'PlugIns/{name}.appex'
        p = load_plist(bundle / 'Info.plist')
        require(p.get('CFBundleIdentifier') == PRODUCTS[name] and
                p.get('CFBundleShortVersionString') == args.version and
                str(p.get('CFBundleVersion')) == args.build and
                p.get('CFBundleExecutable') == name, 'bundle_identity_or_version_mismatch')
        require(p.get('CFBundlePackageType') == ('APPL' if name == 'One' else 'XPC!'), 'bundle_type_mismatch')
        require(p.get('CFBundleSupportedPlatforms') == ['iPhoneOS'], 'device_platform_required')
        if name != 'One':
            expected = 'com.apple.widgetkit-extension' if name == 'TodayWidgets' else 'com.apple.share-services'
            require(p.get('NSExtension', {}).get('NSExtensionPointIdentifier') == expected, 'extension_point_mismatch')
        if not local:
            requirement = ('anchor apple generic and certificate leaf[subject.CN] = "Apple Distribution:"* '
                           'and certificate leaf[subject.OU] = "' + args.team + '"')
            run(['codesign', '--verify', '--deep', '--strict', '-R', requirement, str(bundle)], root)
            ent = plistlib.loads(run(['codesign', '-d', '--entitlements', '-', str(bundle)], root))
            with tempfile.TemporaryDirectory(prefix='today-signature-check-') as tmp:
                prefix = str(Path(tmp) / 'certificate')
                run(['codesign', '-d', '--extract-certificates', prefix, str(bundle)], root)
                allowed = profile(bundle / 'embedded.mobileprovision', name, args.team, root,
                                  leaf_certificate=Path(prefix + '0'))
            expected = load_plist(root / f'ios/{name}.entitlements')
            expected.update({'application-identifier': args.team + '.' + PRODUCTS[name],
                             'com.apple.developer.team-identifier': args.team, 'get-task-allow': False})
            require(all(ent.get(k) == v for k, v in expected.items()), 'signed_entitlements_mismatch')
            # Reject unexpected capabilities as well as missing ones. Only signing-generated
            # keychain groups and beta-reports-active may supplement source entitlements.
            require(set(ent) <= set(expected) | {'keychain-access-groups', 'beta-reports-active'}, 'unexpected_entitlement')
            for k, v in ent.items():
                if k == 'keychain-access-groups':
                    own_group = args.team + '.' + PRODUCTS[name]
                    require(v == [own_group] and any(pattern in (own_group, args.team + '.*')
                            for pattern in allowed.get(k, [])), 'signed_keychain_group_not_in_profile')
                else:
                    require(allowed.get(k) == v, 'signed_entitlement_not_in_profile')
        binaries.append(bundle / name)
    for framework in app.rglob('*.framework'):
        p = load_plist(framework / 'Info.plist')
        executable = p['CFBundleExecutable']
        require(Path(executable).name == executable, 'invalid_framework_executable')
        binaries.append(framework / executable)
    seen = set()
    for binary in binaries:
        require(binary.is_file(), 'executable_missing')
        ids = uuids(binary, root)
        require(not seen & ids and ids <= symbols.keys(), 'executable_dsym_uuid_mismatch')
        seen |= ids
    require(seen == symbols.keys(), 'orphan_dsym_uuid')



def validate_resources(root, app):
    manifest = app / 'PrivacyInfo.xcprivacy'
    require(manifest.is_file(), 'required_privacy_manifest_missing')
    require(load_plist(manifest) == load_plist(root / 'ios/PrivacyInfo.xcprivacy'), 'privacy_manifest_mismatch')
    require((app / 'LICENSE').is_file() and sha(app / 'LICENSE') == sha(root / 'LICENSE'), 'app_license_missing_or_changed')
    notice = app / 'ThirdPartyNotices.txt'
    require(not notice.is_symlink() and notice.is_file(), 'resource_license_notice_missing')
    text = notice.read_text()
    require(all(value in text for value in ('GeoNames', 'https://www.geonames.org',
            'https://creativecommons.org/licenses/by/4.0/', 'transform')), 'geonames_attribution_incomplete')
    for path in app.rglob('*'):
        require(not graph.development_path(path.relative_to(app)), 'development_artifact_in_archive')


def validate_link_maps(root, args, inventory_files):
    # Sealed maps are retained inside the archive by the local archive lane.
    # Parse only the linker object-file section; strings/symbols are not evidence
    # of development dependencies and are deliberately not searched.
    for name in PRODUCTS:
        relative = f'ReleaseEvidence/{name}.map'
        require(relative in inventory_files, 'link_map_missing')
    validate_product_link_maps(root, args.archive / 'Products/Applications/One.app',
                               args.archive / 'ReleaseEvidence')


def bind_product_link_maps(root, app, maps, log):
    """Bind Xcode 27 maps (which omit UUID headers) to this completed real link command."""
    text = log.read_text()
    for name, target in {'One': 'Today', 'TodayWidgets': 'TodayWidgets', 'ShareExtension': 'TodayShare'}.items():
        binary = app / name if name == 'One' else app / 'PlugIns' / (name + '.appex') / name
        linked_binary = binary if name == 'One' else app.parent / (name + '.appex') / name
        require(linked_binary.is_file() and sha(linked_binary) == sha(binary), 'embedded_executable_mismatch')
        path = maps / (target + '-' + name + '.map')
        require(path.is_file() and not path.is_symlink(), 'link_map_missing')
        matched = False
        for line in text.splitlines():
            if str(path) not in line or str(linked_binary) not in line:
                continue
            try:
                args = shlex.split(line)
                index = args.index('-map')
                output = args.index('-o')
                matched = args[index + 1:index + 3] == ['-Xlinker', str(path)] and args[output + 1] == str(linked_binary)
            except (ValueError, IndexError):
                continue
            if matched:
                break
        require(matched, 'completed_link_command_missing')
        headers = path.read_text().splitlines()
        require('# Path: ' + str(linked_binary) in headers and '# Arch: arm64' in headers, 'link_map_product_mismatch')
        receipt = {'schema': 1, 'map_sha256': sha(path), 'executable_sha256': sha(binary),
                   'uuids': sorted(uuids(binary, root)), 'build_log_sha256': sha(log)}
        path.with_suffix('.map.json').write_text(json.dumps(receipt, sort_keys=True) + '\n')


def validate_product_link_maps(root, app, maps, *, target_names=False):
    """Bind each retained link map to its actual executable, including simulator products.

    This proves linked production inputs. It does not establish archive/signing readiness.
    """
    for name in PRODUCTS:
        target = {'One': 'Today', 'TodayWidgets': 'TodayWidgets', 'ShareExtension': 'TodayShare'}[name]
        path = maps / ((target + '-' if target_names else '') + name + '.map')
        require(path.is_file() and not path.is_symlink(), 'link_map_missing')
        lines = path.read_text().splitlines()
        bundle = app
        if name != 'One':
            bundle = bundle / f'PlugIns/{name}.appex'
        map_ids = [line.removeprefix('# UUID: ').upper() for line in lines if line.startswith('# UUID: ')]
        if target_names:
            receipt_path = path.with_suffix('.map.json')
            require(receipt_path.is_file() and not receipt_path.is_symlink(), 'link_receipt_missing')
            receipt = json.loads(receipt_path.read_text())
            require(receipt.get('schema') == 1 and receipt.get('map_sha256') == sha(path)
                    and receipt.get('executable_sha256') == sha(bundle / name)
                    and receipt.get('uuids') == [list(value) for value in sorted(uuids(bundle / name, root))]
                    and bool(re.fullmatch('[0-9a-f]{64}', receipt.get('build_log_sha256', ''))),
                    'link_receipt_product_mismatch')
        else:
            require(len(map_ids) == 1 and map_ids[0] in {uid for uid, _ in uuids(bundle / name, root)},
                    'link_map_executable_uuid_mismatch')
        require('# Object files:' in lines and '# Sections:' in lines, 'invalid_link_map')
        objects = lines[lines.index('# Object files:') + 1:lines.index('# Sections:')]
        require(bool(objects), 'empty_link_map')
        for line in objects:
            match = re.fullmatch(r'\[\s*\d+\]\s+(.+)', line)
            require(match is not None, 'invalid_link_map_object')
            require(not graph.development_path(match[1], object_input=True), 'development_object_in_archive')


def local_preflight(root, args):
    report = Report('preflight-local')
    report.data.update(readiness='unsigned_local', evidence='source_checks_only', signing='not_checked')
    if getattr(args, 'for_install', False):
        report.data.update(readiness='manual_install_candidate', evidence='exact_main_ci_and_device_build',
                           phone='not_installed')
        report.check('release_metadata', lambda: metadata(args, local=True))
        report.check('git_commit_clean', lambda: check_git(root, args.commit))
        def main_gate():
            sys.path.insert(0, str(ROOT))
            from scripts.ci.main_gate import check_install
            try:
                report.data['main_acceptance'] = check_install(root, args, run)
            except ValueError as error:
                code = str(error)
                raise Blocked(code if re.fullmatch(r'main_gate_[a-z_]+', code) else
                              'main_usability_or_device_build_not_accepted') from None
            except (OSError, KeyError, TypeError, zipfile.BadZipFile):
                raise Blocked('main_usability_or_device_build_not_accepted') from None
        report.check('main_usability', main_gate)
        return report
    report.check('release_metadata', lambda: metadata(args, local=True))
    report.check('git_commit_clean', lambda: check_git(root, args.commit))
    report.check('locked_tools', lambda: check_tools(root))
    report.check('release_source_graph', lambda: check_project(root))
    return report


def validate_export(root, args):
    # Never accept an arbitrary/stale IPA merely because an archive passed.
    validate_archive(root, args)
    require(isinstance(args.ipa, Path) and args.ipa.is_file(), 'ipa_required')
    with tempfile.TemporaryDirectory(prefix='today-validate-export-') as tmp:
        destination = Path(tmp)
        with zipfile.ZipFile(args.ipa) as z:
            seen = set()
            for member in z.infolist():
                path = Path(member.filename)
                mode = member.external_attr >> 16
                require(not path.is_absolute() and '..' not in path.parts and
                        member.filename not in seen and (mode & 0o170000) != 0o120000,
                        'unsafe_ipa_entry')
                seen.add(member.filename)
            z.extractall(destination)
            for member in z.infolist():
                if not member.is_dir():
                    (destination / member.filename).chmod((member.external_attr >> 16) & 0o777 or 0o644)
        apps = list((destination / 'Payload').glob('*'))
        require(len(apps) == 1 and apps[0].name == 'One.app', 'ipa_product_mismatch')
        validate_products(root, args, args.archive, apps[0])
        # Export may re-sign Mach-O files; their architecture UUIDs must remain
        # identical to the original dSYMs. All non-signing resources stay identical.
        source = args.archive / 'Products/Applications/One.app'
        require({str(p.relative_to(source)) for p in source.rglob('*') if p.is_file()} ==
                {str(p.relative_to(apps[0])) for p in apps[0].rglob('*') if p.is_file()},
                'export_file_set_changed')
        for original in source.rglob('*'):
            relative = original.relative_to(source)
            if original.is_file() and '_CodeSignature' not in relative.parts and original.name != 'embedded.mobileprovision':
                target = apps[0] / relative
                require(target.is_file(), 'export_resource_missing')
                if sha(original) != sha(target):
                    require(uuids(original, root) == uuids(target, root), 'export_resource_changed')


def authorize(args, env, action):
    metadata(args)
    require(bool(re.fullmatch(r'[0-9a-f]{40}', args.commit)), 'commit_required')
    if action == 'archive':
        require(env.get('TODAY_ARCHIVE_AUTHORIZATION') == 'archive:' + args.commit, 'archive_authorization_required')
    else:
        require(env.get('TODAY_RELEASE_ENVIRONMENT') == 'testflight' and
                env.get('TODAY_DISTRIBUTION_AUTHORIZATION') ==
                f'upload-testflight:{args.commit}:{args.version}:{args.build}', 'distribution_authorization_required')


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['preflight', 'validate', 'seal', 'authorize-archive', 'authorize-distribution', 'validate-export', 'preflight-local', 'seal-local', 'validate-local'])
    p.add_argument('--commit', default='')
    p.add_argument('--version', default='')
    p.add_argument('--build', default='')
    p.add_argument('--team', default='')
    p.add_argument('--archive', type=Path)
    p.add_argument('--ipa', type=Path)
    p.add_argument('--for-install', action='store_true', help='require exact-main merge gate, install smoke and matching device build; installs nothing')
    p.add_argument('--main-run', default='', help='push run of current main (checks + native build)')
    p.add_argument('--smoke-run', default='', help='workflow_dispatch install-smoke run on the same main SHA')
    p.add_argument('--build-receipt', type=Path)
    args = p.parse_args(argv)
    if args.for_install and args.action != 'preflight-local':
        p.error('--for-install requires preflight-local')
    report = Report(args.action)
    if args.action.endswith('-local'):
        report = local_preflight(ROOT, args)
        report.data['action'] = args.action
        if args.action == 'seal-local' and report.data['status'] == 'ready':
            report.check('provenance', lambda: seal(ROOT, args, local=True))
        elif args.action == 'validate-local':
            report.check('unsigned_archive_integrity', lambda: validate_archive(ROOT, args, local=True))
            report.data['evidence'] = 'unsigned_archive_checks_only'
    elif args.action.startswith('authorize-'):
        report.check('authorization', lambda: authorize(args, os.environ, args.action.split('-')[1]))
    elif args.action == 'preflight':
        report = preflight(ROOT, args, os.environ)
    elif args.action == 'seal':
        report.check('provenance', lambda: seal(ROOT, args))
    else:
        report = preflight(ROOT, args, os.environ)
        report.data['action'] = args.action
        if args.action == 'validate-export':
            report.check('export_integrity', lambda: validate_export(ROOT, args))
        else:
            report.check('archive_integrity', lambda: validate_archive(ROOT, args))
    print(json.dumps(report.data, sort_keys=True))
    return 0 if report.data['status'] == 'ready' else 2


if __name__ == '__main__':
    sys.exit(main())
