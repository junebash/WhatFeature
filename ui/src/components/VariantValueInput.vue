<script setup lang="ts">
import { ref, watch } from 'vue'
import type { FlagType, JSONValue } from '../api'

// A variant's value, edited the way its flag's type needs. Objects are JSON text, emitted only once they parse.
const props = defineProps<{ type: FlagType; modelValue: JSONValue }>()
const emit = defineEmits<{ 'update:modelValue': [JSONValue] }>()

const objectText = ref(JSON.stringify(props.modelValue, null, 2))
const problem = ref<string | null>(null)
watch(
  () => props.modelValue,
  (value) => {
    if (problem.value === null && JSON.stringify(value) !== safeCompact(objectText.value)) {
      objectText.value = JSON.stringify(value, null, 2)
    }
  },
)

function safeCompact(text: string): string | undefined {
  try {
    return JSON.stringify(JSON.parse(text))
  } catch {
    return undefined
  }
}

function commitObject() {
  try {
    const value = JSON.parse(objectText.value) as JSONValue
    if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Error('Must be a JSON object, like {"a": 1}')
    problem.value = null
    emit('update:modelValue', value)
  } catch (error) {
    problem.value = error instanceof SyntaxError ? 'Not valid JSON' : (error as Error).message
  }
}

function commitNumber(text: string) {
  const number = Number(text)
  if (text.trim() !== '' && Number.isFinite(number)) emit('update:modelValue', number)
}
</script>

<template>
  <select
    v-if="type === 'boolean'"
    :value="String(modelValue)"
    aria-label="Value"
    @change="emit('update:modelValue', ($event.target as HTMLSelectElement).value === 'true')"
  >
    <option value="true">true</option>
    <option value="false">false</option>
  </select>
  <input
    v-else-if="type === 'string'"
    :value="modelValue as string"
    placeholder="text"
    aria-label="Value"
    @input="emit('update:modelValue', ($event.target as HTMLInputElement).value)"
  />
  <input
    v-else-if="type === 'number'"
    type="number"
    step="any"
    :value="modelValue as number"
    aria-label="Value"
    @input="commitNumber(($event.target as HTMLInputElement).value)"
  />
  <div v-else class="stack tight grow">
    <textarea v-model="objectText" rows="3" :class="{ invalid: problem }" aria-label="Value" @input="commitObject" />
    <span v-if="problem" class="field-error">{{ problem }}</span>
  </div>
</template>
