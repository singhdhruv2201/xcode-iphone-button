#!/usr/bin/env python3
"""Generate credential-free helper Shortcuts and sign them using Apple's CLI.

Action schemas: exported Tailscale AppIntent descriptor, LocalDevVPN's public
VPNShortcuts.swift, and Apple's Set Cellular Data action. Signed exports are
local build resources and must not be committed (signatures may carry identity).
"""
import argparse
from pathlib import Path
import plistlib
import subprocess
import tempfile
import uuid


def action(identifier, **parameters):
    return {'WFWorkflowActionIdentifier': identifier,
            'WFWorkflowActionParameters': {'UUID': str(uuid.uuid4()), **parameters}}


def intent(bundle, name, identifier, **parameters):
    return action(bundle + '.' + identifier,
                  AppIntentDescriptor={'BundleIdentifier': bundle, 'Name': name, 'AppIntentIdentifier': identifier},
                  **parameters)


def tailscale(connect):
    return intent('io.tailscale.ipn.ios', 'Tailscale', 'ConnectIntent' if connect else 'DisconnectIntent')


def localvpn(enable):
    return intent('com.jkcoxson.LocalDevVPN', 'LocalDevVPN', 'ControlLocalDevVPNIntent',
                  operation='enable' if enable else 'disable')


def cellular(on):
    return action('is.workflow.actions.cellulardata.set', operation='set', OnValue=on)


def workflows():
    # Cellular first on recovery, so later action failure cannot strand cellular off.
    return {
        'Probe Connect to Mac': [cellular(True), localvpn(False), tailscale(True)],
        'Probe Prepare Installation': [tailscale(False), localvpn(True), cellular(False)],
        'Probe Restore Internet': [cellular(True), localvpn(False), tailscale(True)],
    }


def generate(destination, mode='anyone'):
    destination.mkdir(parents=True, exist_ok=True)
    for name, actions in workflows().items():
        workflow = {'WFWorkflowName': name, 'WFWorkflowClientVersion': '3036.0.4.2',
                    'WFWorkflowMinimumClientVersion': 900, 'WFWorkflowMinimumClientVersionString': '900',
                    'WFWorkflowActions': actions, 'WFWorkflowImportQuestions': [],
                    'WFWorkflowInputContentItemClasses': [], 'WFWorkflowOutputContentItemClasses': [],
                    'WFWorkflowHasOutputFallback': False, 'WFWorkflowHasShortcutInputVariables': False,
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
    args = parser.parse_args()
    generate(args.output, args.mode)
