// Exercise the shipped Polkit JavaScript without invoking privileged programs.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const profile = process.env.DEVARIO_PROFILE_DIR || path.join(__dirname, '../iso');
const rulePath = '/etc/polkit-1/rules.d/49-devario-live-installer.rules';
const read = name => fs.readFileSync(path.join(profile, name), 'utf8');
const rules = [];
vm.runInNewContext(read('airootfs' + rulePath), {
    polkit: {addRule: rule => rules.push(rule), Result: {YES: 'yes'}},
}, {filename: rulePath, timeout: 1000});
assert.equal(rules.length, 1);

const launchActions = ['io.calamares.calamares.pkexec.run', 'org.freedesktop.policykit.exec'];
const diskAction = 'org.kde.kpmcore.externalcommand.init';
const launch = {program: '/usr/bin/calamares', user: 'root'};
const helper = '/usr/lib/devario/start-installer';
let cases = 0;
function check(id, user, details, expected, session = {}) {
    const actual = rules[0]({id, lookup: key => details[key]}, {user, ...session});
    assert.equal(actual, expected, JSON.stringify({id, user, details, session}));
    cases++;
}

for (const session of [{local: true, active: true}, {local: false, active: false}, {}]) {
    for (const id of launchActions) check(id, 'liveuser', launch, 'yes', session);
    check('org.freedesktop.policykit.exec', 'liveuser', {program: helper, user: 'root'}, 'yes', session);
    check(diskAction, 'liveuser', {}, 'yes', session);
}
for (const user of ['zoey', 'installeduser', 'liveuser2', 'root', undefined]) {
    for (const id of [...launchActions, diskAction]) check(id, user, launch, undefined);
    check('org.freedesktop.policykit.exec', user, {program: helper, user: 'root'}, undefined);
}
for (const user of ['liveuser', 'nobody', undefined]) {
    check('org.freedesktop.policykit.exec', 'liveuser', {program: helper, user}, undefined);
}
check(launchActions[0], 'liveuser', {program: helper, user: 'root'}, undefined);
for (const id of launchActions) {
    for (const program of ['/usr/bin/sh', '/usr/bin/env', '/tmp/calamares', 'calamares', undefined]) {
        check(id, 'liveuser', {...launch, program}, undefined);
    }
    for (const user of ['liveuser', 'nobody', undefined]) {
        check(id, 'liveuser', {...launch, user}, undefined);
    }
    check(id, 'liveuser', {}, undefined);
}
for (const id of ['org.freedesktop.policykit.exec.other', 'org.freedesktop.systemd1.manage-units',
                  diskAction + '.other', 'unrelated.action']) {
    check(id, 'liveuser', launch, undefined);
}

assert.match(read('airootfs/usr/share/applications/install-devario.desktop'),
             /^Exec=\/usr\/lib\/devario\/start-installer$/m);
assert.match(read('late-airootfs/usr/share/applications/calamares.desktop'), /^Hidden=true$/m);
const permissions = JSON.parse(read('profile.json')).permissions;
assert.equal(permissions[rulePath], '644');
assert.equal(permissions['/usr/bin/pkexec'], '4755', 'pkexec must retain its setuid bit in the image');
assert.equal(permissions[helper], '755');
const cleanup = read('airootfs/etc/calamares/modules/prepare_target.conf');
assert.ok(cleanup.includes('rm -f ' + rulePath), 'installed system must remove the live rule');
assert.ok(cleanup.includes('userdel --remove liveuser'), 'installed system must remove the live user');
assert.ok(cleanup.includes('/usr/share/applications/calamares.desktop ' + helper));
console.log(`Live installer authorization: ${cases} policy cases and launcher/cleanup checks passed.`);
