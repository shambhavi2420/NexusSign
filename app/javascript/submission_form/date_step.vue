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
import { toIsoDateString, toUsDateString, todayIsoDateString } from './date_utils'

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
      return todayIsoDateString()
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
        // Stored as MM/DD/YYYY; the native input always hands us YYYY-MM-DD.
        this.$emit('update:model-value', value ? toUsDateString(value) : value)
      },
      get () {
        return this.toIsoDate(this.modelValue)
      }
    }
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

      const isoDate = toIsoDateString(e.clipboardData.getData('text'))

      if (isoDate) {
        const inputEl = this.$refs.input

        inputEl.value = isoDate

        inputEl.dispatchEvent(new Event('input', { bubbles: true }))
      }
    },
    toIsoDate (value) {
      return toIsoDateString(value)
    },
    setCurrentDate () {
      // Assign the string rather than valueAsDate: iOS Safari is inconsistent
      // about valueAsDate on date inputs.
      const inputEl = this.$refs.input

      inputEl.value = todayIsoDateString()

      inputEl.dispatchEvent(new Event('input', { bubbles: true }))
    }
  }
}
</script>
