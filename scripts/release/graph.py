"""Read-only release graph checks; evaluated manifests, never source-string greps."""
import json
from pathlib import Path
import re

FORBIDDEN = {'TodayMock', 'TodayMockApp', 'TodayTestSupport', 'TodayScenes',
             'TodayWorkbench', 'Workbench', 'TestSupport', 'Development',
             'SnapshotTesting', 'OneUITests', 'TodayTests', 'TodayUITests',
             'PreviewFixtures', 'TestDataset', 'DevImport', 'CalendarDemoSeed', 'HealthDebugSeed'}


def development_path(path, object_input=False):
    # Compare complete path/build module components, not arbitrary source strings.
    parts = re.split(r'[/\\()\s]+', str(path))
    return any(part.split('.')[0] in FORBIDDEN or (not object_input and part.lower() in {'fixtures', 'testfixtures', 'tests'})
               for part in parts)


def settings(path):
    result = {}
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('//'):
            continue
        match = re.fullmatch(r'([A-Za-z0-9_]+)\s*=\s*(.*?)\s*', line)
        if not match:
            raise ValueError('unsupported xcconfig syntax')
        result[match[1]] = match[2]
    return result


def check(root, run, require):
    project = json.loads(run(['ruby', '-ryaml', '-rjson', '-e',
        'puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), aliases: false))',
        str(root / 'ios/project.yml')], root))
    require(not project.get('include') and not project.get('targetTemplates'), 'expanded_graph_required')
    package = json.loads(run(['swift', 'package', '--package-path', str(root / 'ios'), 'dump-package'], root))
    targets = {t['name']: t for t in package['targets']}
    products = {p['name']: p['targets'] for p in package['products']}
    visited = set()

    def source(path):
        require(not development_path(path), 'development_source_in_release_graph')

    def visit(name):
        require(name not in FORBIDDEN, 'development_dependency_in_release_graph')
        if name in visited:
            return
        visited.add(name)
        target = targets[name]
        require(target.get('type') == 'regular', 'nonproduction_package_target')
        base = target.get('path') or 'Sources/' + name
        source(base)
        excluded = target.get('exclude', [])
        for file in (root / 'ios' / base).rglob('*'):
            relative = file.relative_to(root / 'ios' / base)
            if file.is_file() and not any(relative == Path(e) or Path(e) in relative.parents for e in excluded):
                source(relative)
        for resource in target.get('resources', []):
            source(resource['path'])
        for item in target.get('sources') or []:
            source(item)
        for dep in target.get('dependencies', []):
            require(set(dep) <= {'byName', 'target'}, 'external_release_dependency_requires_audit')
            value = dep.get('byName', dep.get('target'))
            require(value is not None and value[-1] is None, 'conditional_dependency_requires_audit')
            visit(value[0])

    xvisited = set()
    def xvisit(name):
        require(name not in FORBIDDEN, 'development_target_in_release_graph')
        if name in xvisited:
            return
        xvisited.add(name)
        target = project['targets'][name]
        cfg = settings(root / 'ios' / target['configFiles']['Release'])
        identities = {'Today': ('One', 'TodayApp', 'com.luworks.today', 'One.entitlements'),
                      'TodayWidgets': ('TodayWidgets', 'TodayWidgets', 'com.luworks.today.widgets', 'TodayWidgets.entitlements'),
                      'TodayShare': ('ShareExtension', 'ShareExtension', 'com.luworks.today.share', 'ShareExtension.entitlements')}
        require(name in identities, 'unexpected_release_target')
        require(tuple(cfg.get(key) for key in ('PRODUCT_NAME', 'PRODUCT_MODULE_NAME',
                'PRODUCT_BUNDLE_IDENTIFIER', 'CODE_SIGN_ENTITLEMENTS')) == identities[name], 'source_product_identity_mismatch')
        excluded = set(cfg.get('EXCLUDED_SOURCE_FILE_NAMES', '').split())
        for entry in target.get('sources', []):
            entry = {'path': entry} if isinstance(entry, str) else entry
            path = Path(entry['path'])
            source(path)
            absolute = root / 'ios' / path
            for file in absolute.rglob('*') if absolute.is_dir() else [absolute]:
                if file.is_file() and file.name not in excluded:
                    # Excluded source names do not get compiled. Path membership
                    # checks do not inspect comments, text literals or symbols.
                    source(file.relative_to(root / 'ios'))
        for dep in target.get('dependencies', []):
            if 'target' in dep:
                xvisit(dep['target'])
            elif 'package' in dep:
                require(dep['package'] == 'TodayModules', 'external_release_dependency_requires_audit')
                for module in products[dep['product']]:
                    visit(module)
            else:
                require('sdk' in dep, 'unsupported_release_dependency')
        return cfg

    cfg = xvisit('Today')
    require(cfg['PRODUCT_NAME'] == 'One' and cfg['PRODUCT_MODULE_NAME'] == 'TodayApp' and
            cfg['PRODUCT_BUNDLE_IDENTIFIER'] == 'com.luworks.today', 'source_app_identity_mismatch')
    require('One' in visited, 'model_identity_module_missing')
    embeds = {d['target'] for d in project['targets']['Today']['dependencies'] if d.get('embed')}
    require(embeds == {'TodayWidgets', 'TodayShare'}, 'source_extension_embeds_mismatch')
    scheme = project['schemes']['Today']
    require(scheme['archive']['config'] == 'Release' and
            set(scheme['build']['targets']) == {'Today'}, 'production_archive_scheme_mismatch')
    return {'executable_module': 'TodayApp', 'model_module': 'One',
            'xcode_targets': sorted(xvisited), 'package_targets': sorted(visited)}
