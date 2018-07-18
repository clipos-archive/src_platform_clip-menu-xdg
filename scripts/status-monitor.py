#!/usr/local/bin/python
# -*- coding: utf-8 -*-
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright © 2011-2018 ANSSI. All Rights Reserved.
#
# Watch several files for modifications or/and execute commands periodically to update menu-xdg entries
# Copyright 2011 ANSSI
# Author: Mickaël Salaün <clipos@ssi.gouv.fr>

import re
import fcntl
import os
import stat
import pyinotify
import threading
from subprocess import Popen,PIPE
import traceback
import time
import sys
import signal

ACPI_PATH = '/usr/local/bin/acpi'

def touchopen(filename,*args,**kwargs):
    fd = os.open(filename, os.O_RDWR|os.O_CREAT)
    return os.fdopen(fd, *args, **kwargs)


class EventHandler(pyinotify.ProcessEvent):
    def __init__(self, monitor):
        self.monitor = monitor

    def process_default(self, event):
        filename = os.path.join(event.path, event.name)
        if (filename in self.monitor.watch_paths) or (event.path in self.monitor.watch_paths):
            #print(filename)
            self.monitor.update()

class Monitor(object):
    def __init__(self, template_dir='', output_dir='', watch_paths=None, tag_list=[], tempo=None):
        self._update_lock = threading.Lock()
        self.watch_paths = watch_paths
        if type(watch_paths) == str:
            self.watch_paths = [watch_paths]
        self.template_dir = template_dir
        self.output_dir = output_dir
        self.status_re = re.compile('^' + '|'.join([r'(?:{0}:[ ]?(?P<{0}>.*))'.format(i) for i in tag_list]) + '$', re.M)
        self.status_tags = dict(((k,'') for k in tag_list))
        self.status_extra = []
        self.cache = {}
        self.notifier = None
        self.tempo = tempo
        
        if self.watch_paths != None:
            wm = pyinotify.WatchManager()
            mask = pyinotify.IN_MODIFY | pyinotify.IN_MOVED_TO | pyinotify.IN_CREATE | pyinotify.IN_DELETE
            handler = EventHandler(self)
            self.notifier = pyinotify.ThreadedNotifier(wm, handler)
            self.wdd = None
            for fp in self.watch_paths:
                try:
                    if stat.S_ISDIR(os.stat(fp).st_mode):
                        self.wdd = wm.add_watch(fp, mask)
                    else:
                        self.wdd = wm.add_watch(os.path.dirname(fp), mask)
                except OSError, e:
                    self.wdd = wm.add_watch(os.path.dirname(fp), mask)
            self.notifier.start()
        self._start_timer()
        self.update()
    
    def _start_timer(self):
        if self.tempo != None:
            self.timer = threading.Timer(self.tempo, self.update, [True])
            self.timer.start()

    def _parse_status(self):
        self.status_tags = dict(((k,'') for k in self.status_tags))
        self.status_extra = []
        for fp in self.watch_paths:
            with open(fp, 'r') as f:
                fcntl.flock(f, fcntl.LOCK_SH)
                maxend = 0
                status_str = f.read()
                f.close()
                for m in self.status_re.finditer(status_str):
                    end = m.end()
                    if end > maxend:
                        maxend = end
                    for k,v in m.groupdict().iteritems():
                        if v:
                            self.status_tags[k] = v
                self.status_extra.extend(status_str[maxend:].strip().split('\n'))

    def update(self, timer_action=False):
        with self._update_lock:
            try:
                if timer_action:
                    #print('tick')
                    self._start_timer()
                self._update_main()
            except:
                traceback.print_exc()
                if timer_action:
                    print('BUG: I will continue in 3 seconds')
                    time.sleep(3)

    def _update_main(self):
        pass
    
    def _clean_output(self, file_tmpl):
        i = 0
        name = file_tmpl.format(i)
        # dynamic listing needed (if name does not change)
        while name in os.listdir(self.output_dir):
            os.remove(os.path.join(self.output_dir, name))
            i += 1
            name = file_tmpl.format(i)

    def _gen_output(self, file_tmpl):
        i = 0
        name = file_tmpl.format(i)
        while name in os.listdir(self.output_dir):
            i += 1
            name = file_tmpl.format(i)
        return name
        
    def _upgrade(self, template_file, output_file, repl):
        output_str = ''
        with open(os.path.join(self.template_dir, template_file), 'r') as f:
            fcntl.flock(f, fcntl.LOCK_SH)
            output_str = f.read()
            f.close()
        for k,v in repl.iteritems():
            output_str = output_str.replace(k, v)
        with touchopen(os.path.join(self.output_dir, output_file), 'r+') as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            os.fchmod(f.fileno(), 0644)
            f.write(output_str)
            f.truncate()
            f.close()
        #print(os.path.join(self.output_dir, output_file) + ' -> ' + output_str)

    def stop(self):
        if self.watch_paths:
            #print('stopping notifier')
            self.notifier.stop()
        if self.tempo:
            #print('stopping timer')
            self.timer.cancel()

class MediaRoot(Monitor):
    def __init__(self, *args, **kwargs):
        super(self.__class__, self).__init__(tag_list=['level'], *args, **kwargs)

    def _update_main(self):
        self._parse_status()
        try:
            usb_nb = int(self.status_tags['level'])
        except:
            usb_nb = 0
        cache = {'level':usb_nb}
        if self.cache != cache:
            self.cache = cache
            usb_suffix = ''
            media_icon = 'device-notifier'
            if usb_nb > 0:
                usb_state = usb_nb
                media_icon = 'drive-removable-media-usb-pendrive'
                if usb_nb > 1:
                    usb_suffix = 's'
            else:
                usb_state = 'Aucun'
            status = '{0} support{1} USB connecté{1}'.format(usb_state, usb_suffix)
            # Root entry:
            self._upgrade('media.directory', 'root.directory', {'@MEDIA_STATUS@':status, '@MEDIA_ICON@':media_icon})
            # USB umount entries:
            usb_tmpl = 'usb-umount-{0}.desktop'
            # TODO: add custom action (and specific name) to each entry
            self._clean_output(usb_tmpl)
            for i in xrange(usb_nb):
                self._upgrade('usb-umount.desktop', usb_tmpl.format(i), {'@USB_NAME@':str(i+1)})

# TODO: patch acpi to loop itself
class Battery(Monitor):
    batt_re = re.compile(r'^Battery 0: (?P<state>\w+), (?P<load>[0-9]+)%(?:, (?P<time>[0-9]{2}:[0-9]{2}))?')

    def _update_main(self):
        # /proc/acpi/ac_adapter/AC/state
        batt_states = {'Charged':'chargé', 'Charging':'en charge', 'Discharging':'déconnecté', 'Full':'chargé', 'Unknown': 'inconnu'}
        batt_icon = 'no-battery'
        msg_type = ''
        msg_mode = ''
        msg_cont = ''
        p = Popen([ACPI_PATH, '-b'], stdout=PIPE)
        batt_list = p.stdout.read().strip()
        p.stdout.close()
        batt_m = self.batt_re.match(batt_list)
        if batt_m:
            batt_tags = batt_m.groupdict()
            if self.cache != batt_tags:
                self.cache = batt_tags
                batt_load_icon = ''
                batt_state = batt_tags['state']
                try:
                    batt_load = int(batt_tags['load'])
                except:
                    batt_load = 0
                if batt_state == 'Charged' or batt_state == 'Full':
                    batt_icon = 'battery-charged'
                    msg_type = 'notify'
                    msg_mode = 'info'
                    msg_cont = 'La batterie est chargée à {0} %'.format(batt_load)
                elif batt_state == 'Unknown':
                    batt_icon = 'battery-charged'
                    msg_type = 'notify'
                    msg_mode = 'info'
                    msg_cont = 'La batterie est chargée à {0} %'.format(batt_load)
                elif batt_state == 'Charging':
                    if batt_load >= 95:
                        batt_load_icon = ''
                    elif batt_load >= 75:
                        batt_load_icon = '-080'
                    elif batt_load >= 55:
                        batt_load_icon = '-060'
                    elif batt_load >= 35:
                        batt_load_icon = '-040'
                    elif batt_load >= 15:
                        batt_load_icon = '-caution'
                    else:
                        batt_load_icon = '-low'
                    batt_icon = 'battery-charging{0}'.format(batt_load_icon)
                    msg_type = ''
                else:
                    if batt_load >= 90:
                        batt_load_icon = '-100'
                    elif batt_load >= 70:
                        batt_load_icon = '-080'
                    elif batt_load >= 50:
                        batt_load_icon = '-060'
                    elif batt_load >= 30:
                        batt_load_icon = '-040'
                    elif batt_load >= 15:
                        batt_load_icon = '-caution'
                    elif batt_load >= 10:
                        batt_load_icon = '-caution'
                        msg_type = 'notify'
                        msg_mode = 'info'
                        msg_cont = 'Le niveau de la batterie est faible : {0} %'.format(batt_load)
                    elif batt_load >= 5:
                        batt_load_icon = '-low'
                        msg_type = 'notify'
                        msg_mode = 'warning'
                        msg_cont = 'Le niveau de la batterie est très faible : {0} %'.format(batt_load)
                    else:
                        batt_load_icon = '-missing'
                        msg_type = 'popup'
                        msg_mode = 'error'
                        msg_cont = 'Le niveau de la batterie est critique : {0} %'.format(batt_load)
                    batt_icon = 'battery{0}'.format(batt_load_icon)
                batt_time = batt_tags['time']
                if batt_time == None:
                    batt_time = '-'
                else:
                    batt_time += ' h'
                self._upgrade('power.directory', 'root.directory', {'@BATTERY_STATUS@':batt_states[batt_state], '@BATTERY_LOAD@':'{0} %'.format(batt_load), '@BATTERY_TIME@':batt_time, '@BATTERY_ICON@':batt_icon, '@MSG_TYPE@':msg_type, '@MSG_MODE@':msg_mode, '@MSG_CONTENT@':msg_cont})
        else:
            self.cache = None # force recheck at next tick (could be temporary after resuming from suspend)
            self._upgrade('power.directory', 'root.directory', {'@BATTERY_STATUS@':'pas de batterie', '@BATTERY_LOAD@':'-', '@BATTERY_TIME@':'-', '@BATTERY_ICON@':batt_icon, '@MSG_TYPE@':msg_type, '@MSG_MODE@':msg_mode, '@MSG_CONTENT@':msg_cont})
        p.wait()

class Update(Monitor):
    def _update_main(self):

        # TODO: add status : non disponible, prete a etre installee (necessite une connexion a plus haut debit), telechargement en cours, installation echouee...
        if os.path.exists(self.watch_paths[0]):
            status = 'mise à jour disponible (redémarrage nécessaire)'
            icon = 'security-medium'
        else:
            status = 'cœur CLIP à jour'
            icon = 'security-high'

        import version_calculator
        (version, release)=version_calculator.calc()

        try:
            if (version['rm_h'] != version['rm_b']):
                icon = 'security-medium'
                status = 'Niveaux haut et bas incohérents, si la situation persiste, contactez votre support'
        except:
            pass

        if (version['.']['apps']==0 or version['.']['core']==0 ):
            icon = 'security-low'
            status = "Socle incorrectement installé"

        cache = {'status':status, 'icon':icon, 'release':release}
        if self.cache != cache:
            self.cache = cache
            self._upgrade('system.directory', 'root.directory', {'@CLIP_RELEASE@':release, '@UPDATE_STATUS@':status, '@UPDATE_ICON@':icon})

class NetRoot(Monitor):
    ipsec_re = re.compile(r'^(?P<state>[A-Z/]+) \[(?P<dn>[^\]]+)\] \[(?P<src>[^\]]+)\] \[(?P<dst>[^\]]+)\]$')

    def __init__(self, *args, **kwargs):
        super(self.__class__, self).__init__(tag_list=['profile', 'ipsec', 'type', 'level', 'addr', 'gw'], *args, **kwargs)

    def _update_main(self):
        self._parse_status()
        cache = self.status_tags
        cache['_'] = self.status_extra
        if self.cache != cache:
            self.cache = cache
            profile = self.status_tags['profile']
            type = self.status_tags['type']
            try:
                level = int(self.status_tags['level'])
            except:
                level = 0

            if self.status_tags.has_key('addr') and len(self.status_tags['addr']):
                net_addr = self.status_tags['addr']
            else:
                net_addr = "non assignée"

            if self.status_tags.has_key('gw') and len(self.status_tags['gw']):
                net_gw = self.status_tags['gw']
            else:
                net_gw = "inconnue"

            ipsec_conns = self.status_tags['ipsec'].split(';')
            conns = []

            for gw, status in [ipsec_conn.split(':') for ipsec_conn in ipsec_conns if ':' in ipsec_conn]:
                conn = {'name': gw, 'on': False, 'id': '-', 'state': 'inconnu', 'src': 'inconnue', 'dst': 'inconnue'}

                ipsec_m = self.ipsec_re.match(status)

                if ipsec_m:
                    conn['src'] = ipsec_m.group('src')
                    conn['dst'] = ipsec_m.group('dst')
                    conn['id'] = ipsec_m.group('dn')

                    ipsec_state = ipsec_m.group('state')

                    if ipsec_state  == 'IKE':
                        conn['state'] = 'en cours'
                    elif ipsec_state == 'IKE/ESP':
                        conn['state'] = 'établie'
                        conn['on'] = True
                    else:
                        conn['state'] = 'non établie'

                conns.append(conn)

            ipsec_on = all([conn['on'] for conn in conns]) if conns else False

            extra = []
            for xt in self.status_extra:
                extra.append(xt)
            extra = ' - '.join(extra)
            icon = 'vpn-off'
            if type == 'wired':
                net_type = 'filaire'
                if level == 1:
                    if ipsec_on:
                        icon = 'network-ok'
                    else:
                        icon = 'network'
                else:
                    icon = 'network-wired'
            elif type == 'wifi':
                net_type = 'Wi-Fi'
                if ipsec_on:
                    if 0 <= level <= 3:
                        icon = 'network-wireless-ok-{0}'.format(level)
                    else:
                        icon = 'network-wireless-ok'
                else:
                    if 0 <= level <= 3:
                        icon = 'network-wireless-{0}'.format(level)
                    else:
                        icon = 'network-wireless'
            elif type == 'umts':
                net_type = 'radio-mobile'
                if ipsec_on:
                    if 0 <= level <= 4:
                        icon = 'network-umts-ok-{0}'.format(level)
                    else:
                        icon = 'network-umts-ok'
                else:
                    if 0 <= level <= 4:
                        icon = 'network-umts-{0}'.format(level)
                    else:
                        icon = 'network-umts'
            elif type == 'none':
                net_type = 'réseau non configuré'
            else:
                net_type = 'état incohérent'

            # TODO: RMH_GW -> gw DN
            # TODO: NET_ADDR vs. NET_EXTRA

            comment = r"<u>Profil</u> : {} ({})\n<u>Adresse réseau local</u> : {}\n<u>Passerelle par défaut</u> : {}\n<u>Détail</u> : {}\n".format(profile, net_type, net_addr, net_gw, extra)
            for conn in conns:
                comment += r"\n<u>Nom de la passerelle</u> :  {name}\n<u>Adresse de la passerelle</u> : {dst}\n<u>Identifiant du client</u> : {id}\n<u>État de la connexion</u> : {state}\n".format(** conn)

            self._upgrade('net.directory', 'root.directory', {'@COMMENT@':comment, '@NET_ICON@':icon})

class NetList(Monitor):
    def _update_main(self):
        net_tmpl='net-on-{0}.desktop'
        self._clean_output(net_tmpl)
        for path in self.watch_paths:
            if stat.S_ISDIR(os.stat(path).st_mode):
                for dir in os.listdir(path):
                    if stat.S_ISDIR(os.stat(os.path.join(path, dir)).st_mode):
                        self._upgrade('net-on.desktop', self._gen_output(net_tmpl), {'@PROFILE_NAME@':dir})


def signal_sigint(signal, frame):
    print('{0} received SIGINT: exiting'.format(sys.argv[0]))

if __name__ == '__main__':
    templates_dir = '/usr/local/share/desktop-templates'
    var_dir = '/usr/local/var'
    menu_dir = var_dir + '/menu-xdg'

    monitors = []
    try:
        monitors += [MediaRoot(templates_dir, menu_dir+'/media', var_dir+'/usb_status')]
        monitors += [Battery(templates_dir, menu_dir+'/power', tempo=10)]
        monitors += [Update(templates_dir, menu_dir+'/sys', [
            '/usr/local/var/core_avail',
            '/var/pkg/rm_h/lib/dpkg/status',
            '/var/pkg/rm_b/lib/dpkg/status'])]
        monitors += [NetRoot(templates_dir, menu_dir+'/net', '/usr/local/var/net_status')]
        monitors += [NetList(templates_dir, menu_dir+'/net', '/etc/admin/netconf.d')]
        signal.signal(signal.SIGINT, signal_sigint)
        signal.pause()
    finally:
        for m in monitors:
            m.stop()

# vim: set expandtab tabstop=4 softtabstop=4 shiftwidth=4:
