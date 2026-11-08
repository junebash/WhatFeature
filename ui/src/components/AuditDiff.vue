<script setup lang="ts">
import { computed } from 'vue'
import type { AuditEntry } from '../api'
import { jsonLines, lineDiff } from '../model'

// An audit entry's change as a line diff of its before and after JSON. Creates have no before; deletes no after.
const props = defineProps<{ entry: AuditEntry }>()
const lines = computed(() => lineDiff(jsonLines(props.entry.before), jsonLines(props.entry.after)))
</script>

<template>
  <pre class="json"><div v-for="(line, index) in lines" :key="index" class="diff-line" :class="line.kind">{{ line.kind === 'add' ? '+ ' : line.kind === 'remove' ? '- ' : '  ' }}{{ line.text }}</div><div v-if="lines.length === 0" class="muted">No details recorded.</div></pre>
</template>
