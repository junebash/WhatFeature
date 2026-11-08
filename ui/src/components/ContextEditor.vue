<script setup lang="ts">
import { ref, watch } from 'vue'
import type { EvaluationContext, JSONValue } from '../api'
import ScalarInput from './ScalarInput.vue'

// An evaluation context: a targeting key plus typed attributes. `--attr name=value` in the CLI is always text;
// here each attribute picks its type, text by default.
const props = defineProps<{ modelValue: EvaluationContext; attributes?: string[] }>()
const emit = defineEmits<{ 'update:modelValue': [EvaluationContext] }>()

interface Row {
  id: number
  name: string
  value: JSONValue
}
let nextID = 0
function rowsFrom(context: EvaluationContext): Row[] {
  return Object.entries(context)
    .filter(([name]) => name !== 'targetingKey')
    .map(([name, value]) => ({ id: nextID++, name, value }))
}

const targetingKey = ref(props.modelValue.targetingKey ?? '')
const rows = ref<Row[]>(rowsFrom(props.modelValue))

watch(
  () => props.modelValue,
  (context) => {
    if (JSON.stringify(context) === JSON.stringify(build())) return
    targetingKey.value = context.targetingKey ?? ''
    rows.value = rowsFrom(context)
  },
)

function build(): EvaluationContext {
  const context: EvaluationContext = {}
  for (const row of rows.value) if (row.name.trim()) context[row.name.trim()] = row.value
  if (targetingKey.value) context.targetingKey = targetingKey.value
  return context
}

function commit() {
  emit('update:modelValue', build())
}

function addRow(name = '') {
  rows.value.push({ id: nextID++, name, value: '' })
}

function removeRow(id: number) {
  rows.value = rows.value.filter((row) => row.id !== id)
  commit()
}

const listId = `context-attributes-${Math.random().toString(36).slice(2)}`
</script>

<template>
  <div class="stack tight">
    <div class="ctx-row">
      <span class="name mono">targetingKey</span>
      <input v-model="targetingKey" class="grow" placeholder="user or device ID" aria-label="Targeting key" @input="commit" />
    </div>
    <div v-for="row in rows" :key="row.id" class="ctx-row">
      <input v-model="row.name" class="name" placeholder="attribute" aria-label="Attribute name" :list="listId" @input="commit" />
      <ScalarInput :model-value="row.value" @update:model-value="row.value = $event; commit()" />
      <button class="ghost icon" aria-label="Remove attribute" @click="removeRow(row.id)">✕</button>
    </div>
    <datalist :id="listId">
      <option v-for="attribute in attributes ?? []" :key="attribute" :value="attribute" />
    </datalist>
    <div><button class="small" @click="addRow()">Add attribute</button></div>
  </div>
</template>

<style scoped>
.ctx-row { display: flex; gap: 6px; align-items: center; }
.name { width: 140px; flex: none; }
span.name { padding-left: 2px; color: var(--muted); }
</style>
