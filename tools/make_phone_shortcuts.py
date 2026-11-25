#!/usr/bin/env python3
"""Generate credential-free helper Shortcuts and sign them using Apple's CLI.

Action schemas: exported Tailscale AppIntent descriptor, LocalDevVPN's public
VPNShortcuts.swift, and Apple's Set Cellular Data action. Signed exports are
local build resources and must not be committed (signatures may carry identity).
"""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import uuid


def action(identifier, **parameters):
    return {'WFWorkflowActionIdentifier': identifier,
            'WFWorkflowActionParameters': {'UUID': str(uuid.uuid4()), **parameters}}


def intent(bundle, name, identifier, **parameters):
    return action(bundle + '.' + identifier,
                  AppIntentDescriptor={'BundleIdentifier': bundle, 'Name': name, 'AppIntentIdentifier': identifier},
                  ShowWhenRun=False, **parameters)


def tailscale(connect):
    return intent('io.tailscale.ipn.ios', 'Tailscale', 'ConnectIntent' if connect else 'DisconnectIntent')


def localvpn(enable):
    return intent('com.jkcoxson.LocalDevVPN', 'LocalDevVPN', 'ControlLocalDevVPNIntent',
                  operation='enable' if enable else 'disable')


def cellular(on):
    return action('is.workflow.actions.cellulardata.set', operation='set', OnValue=on)


def attachment(value):
    return {'WFSerializationType': 'WFTextTokenAttachment', 'Value': value}


def text_value(text=None, reference=None):
    value = {'string': text if reference is None else '\ufffc', 'attachmentsByRange': {}}
    if reference is not None: value['attachmentsByRange']['{0, 1}'] = reference
    return {'WFSerializationType': 'WFTextTokenString', 'Value': value}


def output(item):
    return {'Type': 'ActionOutput', 'OutputUUID': item['WFWorkflowActionParameters']['UUID'], 'OutputName': 'Result'}


def variable(name):
    return {'Type': 'Variable', 'VariableName': name}


def set_variable(name, value):
    return action('is.workflow.actions.setvariable', WFVariableName=name, WFInput=attachment(value))


def condition(reference, expected, body):
    group = str(uuid.uuid4())
    return [action('is.workflow.actions.conditional', GroupingIdentifier=group, WFControlFlowMode=0,
                   WFCondition=4, WFInput={'Type': 'Variable', 'Variable': attachment(reference)},
                   WFConditionalActionString=text_value(expected)), *body,
            action('is.workflow.actions.conditional', GroupingIdentifier=group, WFControlFlowMode=2)]


def master_workflow(probe_bundle_id):
    def probe(identifier):
        return intent(probe_bundle_id, 'Phone Install Probe', identifier,
                      run=text_value(reference=variable('Probe Run')))
    initial = action('is.workflow.actions.gettext', WFTextActionText=text_value('waiting'))
    poll = probe('PollMasterBuildIntent')
    download = probe('DownloadMasterBuildIntent')
    install = probe('InstallMasterBuildIntent')
    repeat = str(uuid.uuid4())
    return [
        set_variable('Probe Run', {'Type': 'ExtensionInput'}),
        cellular(True), localvpn(False), tailscale(True),
        initial, set_variable('Build status', output(initial)),
        action('is.workflow.actions.repeat.count', GroupingIdentifier=repeat, WFControlFlowMode=0, WFRepeatCount=300),
        *condition(variable('Build status'), 'waiting', [
            poll, set_variable('Build status', output(poll)),
            *condition(variable('Build status'), 'waiting', [action('is.workflow.actions.delay', WFDelayTime=3)]),
        ]),
        action('is.workflow.actions.repeat.count', GroupingIdentifier=repeat, WFControlFlowMode=2),
        *condition(variable('Build status'), 'ready', [
            download,
            *condition(output(download), 'ready', [tailscale(False), localvpn(True), cellular(False), install]),
        ]),
        # Outside all conditions: even a reported app failure restores data first.
        cellular(True), localvpn(False), tailscale(True), probe('FinishMasterBuildIntent'),
    ]


def configured_probe_bundle():
    folder = Path(__file__).resolve().parents[1] / 'experiments' / 'PhoneInstallProbe'
    value = 'org.xcodeiphonebutton.PhoneInstallProbe'
    for filename in ['Config.xcconfig', 'Signing.local.xcconfig']:
        path = folder / filename
        if path.exists():
            matches = re.findall(r'^\s*PROBE_BUNDLE_ID\s*=\s*([A-Za-z0-9.-]+)\s*$', path.read_text(), re.M)
            if matches: value = matches[-1]
    return value


def workflows(probe_bundle_id='org.xcodeiphonebutton.PhoneInstallProbe'):
    # Cellular first on recovery, so later action failure cannot strand cellular off.
    return {
        'Probe Connect to Mac': [cellular(True), localvpn(False), tailscale(True)],
        'Probe Prepare Installation': [tailscale(False), localvpn(True), cellular(False)],
        'Probe Restore Internet': [cellular(True), localvpn(False), tailscale(True)],
        'Probe Build & Install': master_workflow(probe_bundle_id),
    }


def generate(destination, mode='anyone', probe_bundle_id=None):
    destination.mkdir(parents=True, exist_ok=True)
    for name, actions in workflows(probe_bundle_id or configured_probe_bundle()).items():
        workflow = {'WFWorkflowName': name, 'WFWorkflowClientVersion': '3036.0.4.2',
                    'WFWorkflowMinimumClientVersion': 900, 'WFWorkflowMinimumClientVersionString': '900',
                    'WFWorkflowActions': actions, 'WFWorkflowImportQuestions': [],
                    'WFWorkflowInputContentItemClasses': ['WFStringContentItem'] if name == 'Probe Build & Install' else [], 'WFWorkflowOutputContentItemClasses': [],
                    'WFWorkflowHasOutputFallback': False, 'WFWorkflowHasShortcutInputVariables': name == 'Probe Build & Install',
                    'WFQuickActionSurfaces': [], 'WFWorkflowTypes': ['WFWorkflowTypeShowInSearch'],
                    'WFWorkflowIcon': {'WFWorkflowIconStartColor': 4274264319, 'WFWorkflowIconGlyphNumber': 59511}}
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / (name + '.shortcut')
            source.write_bytes(plistlib.dumps(workflow, fmt=plistlib.FMT_BINARY))
            result = subprocess.run(['shortcuts', 'sign', '--mode', mode, '--input', str(source),
                                     '--output', str(destination / source.name)], capture_output=True, timeout=90)
            if result.returncode:
                raise RuntimeError('Apple Shortcut signing failed; no credentials were included in the workflow.')
        print('Signed:', name, flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--mode', choices=['anyone','people-who-know-me'], default='anyone')
    parser.add_argument('--probe-bundle-id', help='Override the locally configured probe bundle identifier')
    args = parser.parse_args()
    generate(args.output, args.mode, args.probe_bundle_id)
