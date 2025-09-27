# React Signing Form

### Example Code

```react
import React from "react"
import { DocusealForm } from '@docuseal/react'

export function App() {
  return (
    <div className="app">
      <DocusealForm
        src="https://docuseal.com/d/{{template_slug}}"
        email="{{signer_email}}"
        onComplete={(data) => console.log(data)}
      />
    </div>
  );
}

```

### Attributes

```json
{
  "src": {
    "type": "string",
    "required": true,
    "description": "Public URL of the document signing form. There are two types of URLs: <li><code>/d/{slug}</code> - template form signing URL can be copied from the template page in the admin dashboard. Also template \"slug\" key can be obtained via the <code>/templates</code> API.</li><li><code>/s/{slug}</code> - individual signer URL. Signer \"slug\" key can be obtained via the <code>/submissions</code> API which is used to initiate signature requests for a template form with recipients.</li>"
  },
  "email": {
    "type": "string",
    "required": false,
    "description": "Email address of the signer. Additional email form step will be displayed if the email attribute is not specified."
  },
  "name": {
    "type": "string",
    "required": false,
    "description": "Name of the signer."
  },
  "role": {
    "type": "string",
    "required": false,
    "description": "The role name or title of the signer.",
    "example": "First Party"
  },
  "token": {
    "type": "string",
    "doc_type": "object",
    "description": "JSON Web Token (JWT HS256) with a payload signed using the API key. <b>JWT can be generated only on the backend.</b>.",
    "required": false,
    "properties": {
      "slug": {
        "type": "string",
        "required": true,
        "description": "Template or Submitter slug. When Submitter slug is used no need to pass additional email param."
      },
      "email": {
        "type": "string",
        "required": false,
        "description": "Email address of the signer. Additional email form step will be displayed if the email attribute is not specified with Template slug."
      },
      "external_id": {
        "type": "string",
        "required": false,
        "description": "Your application-specific unique string key to identify signer within your app."
      },
      "preview": {
        "type": "boolean",
        "required": false,
        "default": false,
        "description": "Show form in preview mode without ability to submit it."
      }
    }
  },
  "preview": {
    "type": "boolean",
    "required": false,
    "default": false,
    "description": "Show form in preview mode without ability to submit it. Completed documents embedded in preview mode require `token` authentication."
  },
  "expand": {
    "type": "boolean",
    "required": false,
    "description": "Expand form on open.",
    "default": true
  },
  "minimize": {
    "type": "boolean",
    "required": false,
    "description": "Set to `true` to always minimize form fields. Requires to click on the field to expand the form.",
    "default": false
  },
  "orderAsOnPage": {
    "type": "boolean",
    "required": false,
    "default": false,
    "description": "Order form fields based on their position on the pages."
  },
  "logo": {
    "type": "string",
    "required": false,
    "description": "Public logo image URL to use in the signing form."
  },
  "language": {
    "type": "string",
    "required": false,
    "description": "UI language: en, es, it, de, fr, nl, pl, uk, cs, pt, he, ar, kr, ja languages are available. Be default the form is displayed in the user browser language automatically."
  },
  "i18n": {
    "type": "object",
    "required": false,
    "default": "{}",
    "description": "Object that contains i18n keys to replace the default UI text with custom values. See <a href=\"https://github.com/docusealco/docuseal/blob/master/app/javascript/submission_form/i18n.js\" class=\"link\" target=\"_blank\" rel=\"nofollow\">submission_form/i18n.js</a> for available i18n keys."
  },
  "goToLast": {
    "type": "boolean",
    "required": false,
    "default": true,
    "description": "Navigate to the last unfinished step."
  },
  "withFieldNames": {
    "type": "boolean",
    "required": false,
    "default": true,
    "description": "Set `false` to hide field name. Hidding field names can be useful for when they are not in the human readable format. Field names are displayed by default."
  },
  "withFieldPlaceholder": {
    "type": "boolean",
    "required": false,
    "default": false,
    "description": "Set `true` to display field name placeholders instead of the field type icons."
  },
  "skipFields": {
    "type": "boolean",
    "required": false,
    "default": false,
    "description": "Allow skipping form fields."
  },
  "autoscrollFields": {
    "type": "boolean",
    "required": false,
    "default": true,
    "description": "Set `false` to disable auto-scrolling to the next document field."
  },
  "sendCopyEmail": {
    "type": "boolean",
    "required": false,
    "description": "Set `false` to disable automatic email sending with signed documents to the signers. Emails with signed documents are sent to the signers by default."
  },
  "backgroundColor": {
    "type": "string",
    "required": false,
    "description": "Form background color. Only HEX color codes are supported.",
    "example": "#d9d9d9"
  },
  "completedRedirectUrl": {
    "type": "string",
    "required": false,
    "description": "URL to redirect to after the submission completion.",
    "example": "https://docuseal.com/success"
  },
  "completedMessage": {
    "type": "object",
    "required": false,
    "description": "Message displayed after the form completion.",
    "properties": {
      "title": {
        "type": "string",
        "required": false,
        "description": "Message title.",
        "example": "Documents have been signed!"
      },
      "body": {
        "type": "string",
        "required": false,
        "description": "Message content.",
        "example": "If you have any questions, please contact us."
      }
    }
  },
  "completedButton": {
    "type": "object",
    "required": false,
    "description": "Customizable button after form completion.",
    "properties": {
      "title": {
        "type": "string",
        "required": true,
        "description": "Button label.",
        "example": "Go Back"
      },
      "url": {
        "type": "string",
        "required": true,
        "description": "Button link. Only absolute URLs are supported.",
        "example": "https://example.com"
      }
    }
  },
  "withTitle": {
    "type": "boolean",
    "required": false,
    "default": true,
    "description": "Set `false` to remove the document title from the form."
  },
  "withDecline": {
    "type": "boolean",
    "required": false,
    "default": false,
    "description": "Set `true` to display the decline button in the form."
  },
  "withDownloadButton": {
    "type": "boolean",
    "required": false,
    "default": true,
    "description": "Set `false` to remove the signed document download button from the completed form card."
  },
  "withSendCopyButton": {
    "type": "boolean",
    "required": false,
    "default": true,
    "description": "Set `false` to remove the signed document send email button from the completed form card."
  },
  "withCompleteButton": {
    "type": "boolean",
    "required": false,
    "default": false,
    "description": "Set `true` to display the complete button in the form header."
  },
  "allowToResubmit": {
    "type": "boolean",
    "required": false,
    "default": true,
    "description": "Set `false` to disallow user to re-submit the form."
  },
  "allowTypedSignature": {
    "type": "boolean",
    "required": false,
    "default": true,
    "description": "Set `false` to disallow users to type their signature."
  },
  "signature": {
    "type": "string",
    "required": false,
    "description": "Allows pre-filling signature fields. The value can be a base64 encoded image string, a public URL to an image, or plain text that will be rendered as a typed signature using a standard font."
  },
  "rememberSignature": {
    "type": "boolean",
    "required": false,
    "description": "Allows to specify whether the signature should be remembered for future use. Remembered signatures are stored in the signer's browser local storage and can be automatically reused to prefill signature fields in new forms for the signer when the value is set to `true`."
  },
  "reuseSignature": {
    "type": "boolean",
    "required": false,
    "default": true,
    "description": "Set `false` to not reuse the signature in the second signature field and collect a new one."
  },
  "values": {
    "type": "object",
    "required": false,
    "description": "Pre-assigned values for form fields.",
    "example": "{ 'First Name': 'Jon', 'Last Name': 'Doe' }"
  },
  "externalId": {
    "type": "string",
    "required": false,
    "description": "Your application-specific unique string key to identify signer within your app."
  },
  "metadata": {
    "type": "object",
    "required": false,
    "description": "Metadata object with additional signer information.",
    "example": "{ customData: 'custom value' }"
  },
  "readonlyFields": {
    "type": "array",
    "required": false,
    "description": "List of read-only fields.",
    "example": "['First Name','Last Name']"
  },
  "customCss": {
    "type": "string",
    "required": false,
    "description": "Custom CSS styles to be applied to the form.",
    "example": "#submit_form_button { background-color: #d9d9d9; }"
  }
}
```

### Callback

```json
{
  "onInit": {
    "type": "function",
    "required": false,
    "description": "Function to be called on initializing the form component.",
    "example": "() => { console.log(\"Loaded\") }"
  },
  "onLoad": {
    "type": "function",
    "required": false,
    "description": "Function to be called on loading the form data.",
    "example": "(data) => { console.log(data) }"
  },
  "onComplete": {
    "type": "function",
    "required": false,
    "description": "Function to be called after the form completion.",
    "example": "(data) => { console.log(data) }"
  },
  "onDecline": {
    "type": "function",
    "required": false,
    "description": "Function to be called after the form decline.",
    "example": "(data) => { console.log(data) }"
  }
}
```
