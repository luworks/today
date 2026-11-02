"""Today development commands; doctor, inventory and plan are read-only."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

from .core import (compiler_module_cache, derived_data, fingerprint, inspect_lock, provenance,
                   state_root, toolchain, worktree_id)
from .process import Redactor

ROOT = Path(__file__).resolve().parents[2]


def inventory(root):
    tools = toolchain()
    return {'worktree': str(root), 'worktree_id': worktree_id(root),
            'derived_data': str(derived_data(root)), 'toolchain': tools,
            'host_heavy': inspect_lock(state_root(root) / 'locks/host-heavy.lock'),
            'derived_data_lock': inspect_lock(state_root(root) / 'locks' / (worktree_id(root) + '.lock')),
            'existing_entrypoints': {name: str(root / path) for name, path in {
                'ui_runner': 'ios/Eval/run-e2e.py', 'preview': 'scripts/swiftui_preview.py'}.items()
                if (root / path).is_file()}}


def main(argv=None, root=ROOT):
    parser = argparse.ArgumentParser(prog='./dev', description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('help', help='show supported commands')
    sub.add_parser('doctor', help='read-only environment checks; no simulator boot')
    sub.add_parser('inventory', help='read-only worktree, locks and tools')
    cleanup = sub.add_parser('cleanup', help='dry-run retention; --apply removes only eligible generated artifacts')
    cleanup.add_argument('--apply', action='store_true')
    plan = sub.add_parser('plan', help='read-only fingerprint and provenance; executes nothing')
    plan.add_argument('--scheme', choices=['Today', 'TodayMock', 'TodayWorkbench', 'TodayTests', 'TodaySnapshotTests', 'TodayCI'], default='Today')
    plan.add_argument('--sdk', default='iphonesimulator')
    plan.add_argument('--architecture')
    plan.add_argument('--configuration', choices=['Debug', 'Release'], default='Debug')
    bootstrap_parser = sub.add_parser('bootstrap', help='install exact checksummed worktree-local tools')
    bootstrap_parser.add_argument('--tool', action='append')
    check_parser = sub.add_parser('check', help='run selected existing verification authorities')
    check_parser.add_argument('--check', action='append')
    check_parser.add_argument('--timeout', type=float, default=600)
    benchmark_parser = sub.add_parser('benchmark', help='measure actual bounded command invocations')
    benchmark_parser.add_argument('kind', choices=['cold', 'incremental', 'unit', 'ui', 'screenshot', 'gallery'])
    benchmark_parser.add_argument('--n', type=int, default=1)
    benchmark_parser.add_argument('--conditions', required=True)
    benchmark_parser.add_argument('--timeout', type=float, default=600)
    benchmark_parser.add_argument('--argument', dest='options', action='append', default=[])
    report_parser = sub.add_parser('report', help='read retained run receipts without changing state')
    report_parser.add_argument('paths', nargs='*', type=Path)
    sub.add_parser('generate', help='generate Today.xcodeproj from the sole specification')
    resolve_parser = sub.add_parser('resolve', help='resolve only versioned exact dependency pins')
    resolve_parser.add_argument('--scheme', choices=['Today', 'TodayMock', 'TodayWorkbench', 'TodayTests', 'TodaySnapshotTests'], default='Today')
    build_parser = sub.add_parser('build', help='build the real app and embedded extensions')
    build_parser.add_argument('configuration', nargs='?', choices=['Debug', 'Release'], default='Debug')
    build_parser.add_argument('--scheme', choices=['Today', 'TodayMock', 'TodayWorkbench'], default='Today')
    build_parser.add_argument('--device', help='paired physical device identifier')
    build_parser.add_argument('--install', action='store_true', help='install after exact-main CI preflight')
    build_parser.add_argument('--allow-provisioning-updates', action='store_true')
    build_parser.add_argument('--main-run', help='main push run ID (default: looked up for the SHA)')
    build_parser.add_argument('--smoke-run', help='run with a green install-smoke (default: the main push run)')
    build_parser.add_argument('--for-testing', action='store_true', help='prepare authoritative test products without booting a device or running tests')
    build_parser.add_argument('--timeout', type=float, default=None, help='per-process seconds; default 600')
    test_parser = sub.add_parser('test', help='run an authoritative test group')
    test_parser.add_argument('group', choices=['helpers', 'qa', 'unit', 'ios-unit', 'integration', 'ui', 'snapshot', 'accessibility', 'core', 'release'])
    test_parser.add_argument('--only', action='append', default=[])
    test_parser.add_argument('--allow-skip', action='append', default=[], choices=['hardware', 'screenshot', 'time'])
    test_parser.add_argument('--timeout', type=float, default=None, help='per-process seconds; default 600')
    test_parser.add_argument('--full', action='store_true', help='only for an explicitly authorized frozen final revision')
    format_parser = sub.add_parser('format', help='Apple swift-format only')
    format_parser.add_argument('--check', action='store_true')
    sub.add_parser('lint', help='SwiftLint, maintained Python Ruff and actionlint')
    release_parser = sub.add_parser('release', help='guarded release preflight/archive/validate')
    release_parser.add_argument('action', choices=['preflight', 'archive', 'validate', 'preflight-local', 'archive-local', 'validate-local'])
    release_parser.add_argument('options', nargs=argparse.REMAINDER)
    feature_parser = sub.add_parser('new-feature', help='create a linked native feature or verify a temporary one')
    feature_parser.add_argument('name')
    feature_parser.add_argument('--verify', action='store_true')
    ui_parser = sub.add_parser('ui', help='open/capture actual registered native scenes or serve their loopback gallery')
    ui_sub = ui_parser.add_subparsers(dest='ui_action', required=True)
    for verb in ('open', 'capture'):
        action = ui_sub.add_parser(verb)
        action.add_argument('--scene', required=True)
        action.add_argument('--scenario', default='normal')
        action.add_argument('--appearance', choices=['system', 'light', 'dark'], default='light')
        action.add_argument('--type-size', default='large')
        action.add_argument('--locale', default='en_US')
        if verb == 'capture':
            action.add_argument('--output', type=Path, required=True)
    gallery_parser = ui_sub.add_parser('gallery')
    gallery_parser.add_argument('--watch', action=argparse.BooleanOptionalAction, default=True)
    gallery_parser.add_argument('--port', type=int, default=0)
    args = parser.parse_args(argv)
    if args.command == 'help':
        parser.print_help()
        return 0
    try:
        root = Path(root).resolve()
        if args.command == 'cleanup':
            sys.path.insert(0, str(root / 'tests/qa'))
            from retention import run
            print(json.dumps(run(root, apply=args.apply), indent=2))
            return 0
        if args.command == 'report':
            from .report import collect
            result = collect(root, args.paths)
            print(Redactor()(json.dumps(result, indent=2, sort_keys=True)))
            return result['exit']
        if args.command not in ('doctor', 'inventory', 'plan'):
            if args.command == 'check':
                from .check import run, DEFAULT_CHECKS
                result = run(root, args.check if args.check is not None else DEFAULT_CHECKS, timeout=args.timeout)
                print(Redactor()(json.dumps(result, indent=2)))
                return result['exit']
            if args.command == 'benchmark':
                from .benchmark import run
                result = run(root, args.kind, n=args.n, arguments=args.options, conditions=args.conditions, timeout=args.timeout)
                print(Redactor()(json.dumps(result, indent=2)))
                return result['exit']
            from . import commands
            if args.command == 'ui':
                from . import ui
                if args.ui_action == 'gallery':
                    ui.gallery(root, watch=args.watch, port=args.port)
                else:
                    options = dict(appearance=args.appearance, type_size=args.type_size, locale=args.locale)
                    if args.ui_action == 'capture':
                        identity = ui.capture(root, args.scene, args.scenario, args.output, **options)
                    else:
                        identity = ui.open_scene(root, args.scene, args.scenario, **options)
                    print(json.dumps({'device': identity.device, 'os': identity.os}))
                return 0
            if args.command == 'new-feature':
                from .new_feature import create, temporary
                if args.verify:
                    with temporary(root, args.name):
                        code = commands.generate(root)
                        if not code:
                            code = commands.build(root, scheme='Today')
                    restored = commands.generate(root)
                    return code or restored
                print(json.dumps(create(root, args.name).as_dict(), indent=2))
                return 0
            if args.command == 'bootstrap':
                print(json.dumps(commands.bootstrap(root, tools=args.tool), indent=2))
                return 0
            if args.command == 'resolve':
                from .resolve import run
                return run(root, args.scheme)
            if args.command == 'generate':
                return commands.generate(root)
            if args.command == 'build':
                options = {} if args.timeout is None else {'timeout': args.timeout}
                if args.for_testing:
                    options['testing'] = True
                if args.device or args.install or args.allow_provisioning_updates or args.main_run or args.smoke_run:
                    options.update(device=args.device, install=args.install, provisioning_updates=args.allow_provisioning_updates,
                                   main_run=args.main_run, smoke_run=args.smoke_run)
                return commands.build(root, args.configuration, scheme=args.scheme, **options)
            if args.command == 'test':
                if args.full and args.group not in ('ui', 'release'):
                    raise ValueError('--full requires ui or release collection')
                options = {} if args.timeout is None else {'timeout': args.timeout}
                if args.allow_skip:
                    if args.group not in ('ui', 'core', 'accessibility', 'release'):
                        raise ValueError('--allow-skip is only supported for UI collections')
                    options['allow_skips'] = args.allow_skip
                if args.timeout is not None and args.timeout <= 0:
                    raise ValueError('--timeout must be positive')
                code = commands.test(root, args.group, only=args.only, full=args.full, **options)
                if args.group in ('ui', 'core', 'accessibility', 'release'):
                    sys.path.insert(0, str(root / 'tests/qa'))
                    from retention import after_run
                    after_run(root)
                return code
            if args.command == 'format':
                return commands.format_sources(root, check=args.check)
            if args.command == 'lint':
                return commands.lint(root)
            if args.command == 'release':
                return commands.release(root, args.action, args.options)
        data = inventory(root)
        if args.command == 'doctor':
            from .doctor import inspect
            data = {'worktree': str(root), **inspect(root)}
            code = 0 if data['ok'] else 1
        elif args.command == 'plan':
            current = fingerprint(root, sdk=args.sdk, architecture=args.architecture,
                                  configuration=args.configuration, tools=data['toolchain'], scheme=args.scheme)
            data.update({'fingerprint': current, 'provenance': provenance(root, current),
                         'compiler_module_cache': compiler_module_cache(root, current),
                         'execution_supported': True,
                         'next': './dev generate; ./dev resolve; ./dev build Debug'})
            code = 0
        else:
            code = 0
        print(Redactor()(json.dumps(data, indent=2, sort_keys=True)))
        return code
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print('dev: ' + Redactor()(str(error)), file=sys.stderr)
        return 1
