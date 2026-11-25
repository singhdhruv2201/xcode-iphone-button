"""Exercise the generated control flow without changing the host's network."""
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from make_phone_shortcuts import master_workflow


def simulate(statuses, download='ready', installation='installed'):
    actions = master_workflow('org.example.Probe')
    variables = {}; outputs = {}; events = []; polls = iter(statuses)
    def value(x):
        if not isinstance(x, dict): return x
        if x.get('WFSerializationType') == 'WFTextTokenAttachment': return value(x['Value'])
        if x.get('WFSerializationType') == 'WFTextTokenString':
            text = x['Value']
            if text['attachmentsByRange']: return value(next(iter(text['attachmentsByRange'].values())))
            return text['string']
        if x.get('Type') == 'Variable': return value(x['Variable']) if 'Variable' in x else variables[x['VariableName']]
        if x.get('Type') == 'ExtensionInput': return 'synthetic-run-token'
        if x.get('Type') == 'ActionOutput': return outputs[x['OutputUUID']]
        raise AssertionError('Unknown variable format')
    def execute(start, end):
        i = start
        while i < end:
            item = actions[i]; name = item['WFWorkflowActionIdentifier']; p = item['WFWorkflowActionParameters']
            if p.get('WFControlFlowMode') == 0:
                close = next(j for j in range(i+1, end) if actions[j]['WFWorkflowActionParameters'].get('GroupingIdentifier') == p['GroupingIdentifier'] and actions[j]['WFWorkflowActionParameters'].get('WFControlFlowMode') == 2)
                if name.endswith('repeat.count'):
                    assert p['WFRepeatCount'] == 300
                    for _ in range(p['WFRepeatCount']): execute(i+1, close)
                else:
                    assert name.endswith('conditional') and p['WFCondition'] == 4
                    if value(p['WFInput']) == value(p['WFConditionalActionString']): execute(i+1, close)
                i = close + 1; continue
            result = None
            if name.endswith('setvariable'): variables[p['WFVariableName']] = value(p['WFInput'])
            elif name.endswith('gettext'): result = value(p['WFTextActionText'])
            elif name.endswith('delay'): assert p['WFDelayTime'] == 3
            elif name.startswith('org.example.Probe.'):
                assert value(p['run']) == 'synthetic-run-token'
                action = name.rsplit('.',1)[1]; events.append(action)
                if action == 'PollMasterBuildIntent': result = next(polls, statuses[-1])
                elif action == 'DownloadMasterBuildIntent': result = download
                elif action == 'InstallMasterBuildIntent': result = installation
            elif name.endswith('cellulardata.set'): events.append('cellular-on' if p['OnValue'] else 'cellular-off')
            elif name.endswith('ControlLocalDevVPNIntent'): events.append('local-'+p['operation'])
            elif name.endswith('DisconnectIntent'): events.append('tailscale-off')
            elif name.endswith('ConnectIntent'): events.append('tailscale-on')
            else: raise AssertionError('Unknown action '+name)
            outputs[p['UUID']] = result
            i += 1
    execute(0, len(actions))
    return events


class MasterShortcutTests(unittest.TestCase):
    def assert_restoration(self, events):
        self.assertEqual(events[-4:], ['cellular-on','local-disable','tailscale-on','FinishMasterBuildIntent'])
    def test_success_waits_until_ready_and_installs_once(self):
        events = simulate(['waiting','waiting','ready'])
        self.assertEqual(events.count('PollMasterBuildIntent'), 3)
        self.assertEqual(events.count('InstallMasterBuildIntent'), 1)
        install = events.index('InstallMasterBuildIntent')
        self.assertEqual(events[install-3:install], ['tailscale-off','local-enable','cellular-off'])
        self.assert_restoration(events)
    def test_build_failure_or_poll_limit_never_enters_offline_mode(self):
        for statuses in [['waiting','failed'],['waiting']]:
            events = simulate(statuses)
            self.assertNotIn('DownloadMasterBuildIntent',events)
            self.assertNotIn('cellular-off',events)
            self.assert_restoration(events)
    def test_failed_download_skips_install_and_reported_install_failure_restores(self):
        events = simulate(['ready'], download='failed')
        self.assertNotIn('cellular-off',events)
        self.assertNotIn('InstallMasterBuildIntent',events)
        self.assert_restoration(events)
        self.assert_restoration(simulate(['ready'], installation='failed'))

if __name__ == '__main__': unittest.main()
