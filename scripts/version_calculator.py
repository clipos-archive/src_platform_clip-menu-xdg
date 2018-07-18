#!/usr/local/bin/python
# -*- coding: utf-8 -*-
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright © 2011-2018 ANSSI. All Rights Reserved.
import re
import fcntl

def calc():
	with open('/etc/shared/clip-release', 'r') as f:
		fcntl.flock(f, fcntl.LOCK_SH)
		release = f.readline().split('-')[0]
		f.close()

	version = {
			'rm_h' : {'apps':0, 'core':0},
			'rm_b' : {'apps':0, 'core':0},
			'.' : {'apps':0, 'core':0}
			}

	for cage in ['rm_h','rm_b','.']:
		try:
			with open('/var/pkg/'+ cage +'/lib/dpkg/status', 'r') as f:
				for line in f:
					line = re.findall(r'^(Source:.*)-(apps|core)-conf(.*)-r(.*)', line)
					if line:
						line = line[0]
						version[cage][line[1]]=int(line[3])
				f.close()
		except Exception:
			del version[cage]

	version_total = version['.']['apps'] + version['.']['core']
	try:
		version_total += version['rm_h']['apps'] + version['rm_h']['core']
	except Exception:
		version['rm_h']={}
		version['rm_h']['apps']=0
		version['rm_h']['core']=0
		try:
			version_total += version['rm_b']['apps'] + version['rm_b']['core']
		except Exception:
			version['rm_b']={}
			version['rm_b']['apps']=0
			version['rm_b']['core']=0

	release += "-r"+str(version_total) +\
				" (cc" + str(version['.']['core']) +\
				"-ca" + str(version['.']['apps'])
	if (version['rm_h']['apps']!=0 or version['rm_h']['core']!=0):
		release +=  "-rc" + str(version['rm_h']['core']) +\
					"-ra" + str(version['rm_h']['apps'])
	elif (version['rm_b']['apps']!=0 or version['rm_b']['core']!=0):
		release +=  "-rc" + str(version['rm_b']['core']) +\
					"-ra" + str(version['rm_b']['apps'])
	release +=  ")"
	return ( version, release )

if __name__ == "__main__":
	( version, release ) = calc()
	print release
