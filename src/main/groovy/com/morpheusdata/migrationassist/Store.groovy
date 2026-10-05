package com.morpheusdata.migrationassist

import groovy.json.JsonOutput
import groovy.json.JsonSlurper

/**
 * Plugin state as JSON files in a directory the UI user can write (same approach as hvm-updater).
 *   config.json            credential assignments (references only, never secrets)
 *   snapshots/plan-N.json  per-plan NIC snapshots, keyed by source server id
 */
class Store {

    final File dir

    Store(String path) { this.dir = new File(path) }

    synchronized Map read(String name) {
        File f = new File(dir, name)
        try { return f.exists() ? (new JsonSlurper().parseText(f.getText('UTF-8')) as Map) : [:] }
        catch (Exception e) { return [:] }
    }

    synchronized void write(String name, Map data) {
        File f = new File(dir, name)
        f.parentFile.mkdirs()
        File tmp = new File(f.parentFile, f.name + '.tmp')
        tmp.setText(JsonOutput.prettyPrint(JsonOutput.toJson(data)), 'UTF-8')
        if (!tmp.renameTo(f)) { f.delete(); tmp.renameTo(f) }
    }

    Map config() { read('config.json') }
    void saveConfig(Map c) { write('config.json', c) }

    Map snapshot(Long planId) { read("snapshots/plan-${planId}.json") }
    void saveSnapshot(Long planId, Map s) { write("snapshots/plan-${planId}.json", s) }
}
