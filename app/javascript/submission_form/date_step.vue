<template>
  <div dir="auto">
    <div
      class="flex justify-between items-end w-full mb-3.5 sm:mb-4"
      :class="{ 'mb-2': !field.description }"
    >
      <label
        v-if="showFieldNames"
        :for="field.uuid"
        class="label text-xl sm:text-2xl py-0 field-name-label"
      >
        <MarkdownContent
          v-if="field.title"
          :string="field.title"
        />
        <template v-else>
          {{ field.name || t('date') }}
        </template>
        <template v-if="!field.required">
          <span
            class="ml-1"
            :class="{ 'hidden sm:inline': (field.title || field.name || t('date') ).length > 10 }"
          >
            ({{ t('optional') }})
          </span>
        </template>
      </label>
      <button
        v-if="withToday"
        class="btn btn-outline btn-sm !normal-case font-normal set-current-date-button"
        @click.prevent="[setCurrentDate(), $emit('focus')]"
      >
        <IconCalendarCheck :width="16" />
        {{ t('set_today') }}
      </button>
    </div>
    <div
      v-if="field.description"
      class="mb-3 px-1 field-description-text"
      dir="auto"
    >
      <MarkdownContent :string="field.description" />
    </div>
    <AppearsOn :field="field" />
    <div class="text-center">
      <input
        :id="field.uuid"
        ref="input"
        v-model="value"
        :min="validationMin"
        :max="validationMax || '9999-12-31'"
        class="base-input !text-2xl text-center w-full"
        :required="field.required"
        type="date"
        :name="`values[${field.uuid}]`"
        @keydown.enter="onEnter"
        @focus="$emit('focus')"
        @paste="onPaste"
      >
    </div>
  </div>
</template>

<script>
import { IconCalendarCheck } from '@tabler/icons-vue'
import AppearsOn from './appears_on'
import MarkdownContent from './markdown_content'

export default {
  name: 'DateStep',
  components: {
    IconCalendarCheck,
    MarkdownContent,
    AppearsOn
  },
  inject: ['t'],
  props: {
    field: {
      type: Object,
      required: true
    },
    showFieldNames: {
      type: Boolean,
      required: false,
      default: true
    },
    modelValue: {
      type: String,
      required: false,
      default: ''
    }
  },
  emits: ['update:model-value', 'focus', 'submit'],
  computed: {
    dateNowString () {
      const today = new Date()

      const yyyy = today.getFullYear()
      const mm = String(today.getMonth() + 1).padStart(2, '0')
      const dd = String(today.getDate()).padStart(2, '0')

      return `${yyyy}-${mm}-${dd}`
    },
    validationMin () {
      if (this.field.validation?.min) {
        return ['{{date}}', '{date}'].includes(this.field.validation.min) ? this.dateNowString : this.field.validation.min
      } else {
        return ''
      }
    },
    validationMax () {
      if (this.field.validation?.max) {
        return ['{{date}}', '{date}'].includes(this.field.validation.max) ? this.dateNowString : this.field.validation.max
      } else {
        return ''
      }
    },
    withToday () {
      const todayDate = new Date().setHours(0, 0, 0, 0)

      if (this.validationMin) {
        if (new Date(this.validationMin).setHours(0, 0, 0, 0) <= todayDate) {
          return this.validationMax ? (new Date(this.validationMax).setHours(0, 0, 0, 0) >= todayDate) : true
        } else {
          return false
        }
      } else if (this.validationMax) {
        return new Date(this.validationMax).setHours(0, 0, 0, 0) >= todayDate
      } else {
        return true
      }
    },
value: {
  set (value) {
    // Convert YYYY-MM-DD back to MM/DD/YYYY before storing
    if (value && /^\d{4}-\d{2}-\d{2}$/.test(value)) {
      const parts = value.split('-')
      value = `${parts[1]}/${parts[2]}/${parts[0]}`
    }
    this.$emit('update:model-value', value)
  },
  get () {
    return this.toIsoDate(this.modelValue)
  }
},
  },
  mounted () {
    this.$nextTick(() => {
      if (this.modelValue && this.$refs.input) {
        const isoDate = this.toIsoDate(this.modelValue)

        if (isoDate && /^\d{4}-\d{2}-\d{2}$/.test(isoDate)) {
          this.$refs.input.value = isoDate
        }
      }
    })
  },
  methods: {
    onEnter (e) {
      if (this.modelValue) {
        e.preventDefault()

        this.$emit('submit')
      }
    },
    onPaste (e) {
      e.preventDefault()

      let pasteData = e.clipboardData.getData('text').trim()

      if (pasteData.match(/^\d{2}\.\d{2}\.\d{4}$/)) {
        pasteData = pasteData.split('.').reverse().join('-')
      }

      const parsedDate = new Date(pasteData)

      if (!isNaN(parsedDate)) {
        const inputEl = this.$refs.input

        inputEl.valueAsDate = new Date(parsedDate.getTime() - parsedDate.getTimezoneOffset() * 60000)

        inputEl.dispatchEvent(new Event('input', { bubbles: true }))
      }
    },
toIsoDate (value) {
  if (!value) return value
  value = String(value).trim()
  if (/^\d{4}-\d{2}-\d{2}$/.test(value)) return value
  // Handle M/D/YYYY, MM/DD/YYYY, M-D-YYYY, MM-DD-YYYY (1 or 2 digit month/day)
  const match = value.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4})$/)
  if (match) {
    const mm = match[1].padStart(2, '0')
    const dd = match[2].padStart(2, '0')
    return `${match[3]}-${mm}-${dd}`
  }
  // Fallback: try parsing as a date
  const parsed = new Date(value)
  if (!isNaN(parsed)) {
    const yyyy = parsed.getFullYear()
    const mm = String(parsed.getMonth() + 1).padStart(2, '0')
    const dd = String(parsed.getDate()).padStart(2, '0')
    return `${yyyy}-${mm}-${dd}`
  }
  return value
},
    setCurrentDate () {
      const inputEl = this.$refs.input

      inputEl.valueAsDate = new Date(new Date().getTime() - new Date().getTimezoneOffset() * 60000)

      inputEl.dispatchEvent(new Event('input', { bubbles: true }))
    }
  }
}
</script>
